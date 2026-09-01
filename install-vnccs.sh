#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ComfyUI + VNCCS RunPod bootstrap
#
# Goal:
#   Start from a fresh, WORKING RunPod ComfyUI template and
#   reproduce the VNCCS setup without using Manager/VNCCS
#   browser-side installers (avoids RunPod cross-origin issues).
#
# Tested target:
#   - RunPod
#   - NVIDIA RTX 4090
#   - ComfyUI under /workspace/runpod-slim/ComfyUI
#   - Qwen Image Edit 2511 GGUF Q8
#
# Usage:
#   chmod +x install-vnccs.sh
#   ./install-vnccs.sh
#
# Optional:
#   COMFYUI_DIR=/workspace/ComfyUI ./install-vnccs.sh
#   QIE_QUANT=Q5 ./install-vnccs.sh
#   SKIP_MODELS=1 ./install-vnccs.sh
#
# IMPORTANT:
#   This script intentionally preserves the RunPod-installed
#   PyTorch/CUDA stack. It does NOT upgrade torch/torchvision/
#   torchaudio when updating ComfyUI requirements.
# ============================================================

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
QIE_QUANT="${QIE_QUANT:-Q8}"
SKIP_MODELS="${SKIP_MODELS:-0}"

case "$QIE_QUANT" in
    Q4|Q5|Q8) ;;
    *)
        echo "ERROR: QIE_QUANT must be Q4, Q5, or Q8."
        exit 1
        ;;
esac

log() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || die "git is not installed."

[ -d "$COMFYUI_DIR" ] || die "ComfyUI directory not found: $COMFYUI_DIR"
[ -f "$COMFYUI_DIR/main.py" ] || die "ComfyUI main.py not found: $COMFYUI_DIR/main.py"

cd "$COMFYUI_DIR"

# ------------------------------------------------------------
# Locate ComfyUI's existing Python environment.
# ------------------------------------------------------------

VENV=""

for candidate in \
    ".venv-cu128" \
    ".venv-cu130" \
    ".venv" \
    "venv"
do
    if [ -x "$candidate/bin/python" ]; then
        VENV="$candidate"
        break
    fi
done

[ -n "$VENV" ] || die "Could not find ComfyUI virtual environment."

# shellcheck disable=SC1090
source "$VENV/bin/activate"

PYTHON="$(command -v python)"
[ -n "$PYTHON" ] || die "Python not available after activating $VENV"

echo "ComfyUI: $COMFYUI_DIR"
echo "Venv:    $VENV"
echo "Python:  $PYTHON"
python --version

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

remote_default_ref() {
    local repo="$1"
    local ref=""

    ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -n "$ref" ]; then
        echo "$ref"
        return
    fi

    if git -C "$repo" show-ref --verify --quiet refs/remotes/origin/master; then
        echo "origin/master"
    elif git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main; then
        echo "origin/main"
    else
        return 1
    fi
}

update_git_repo_hard() {
    local repo="$1"
    local label="$2"

    if [ ! -d "$repo/.git" ]; then
        echo "WARNING: $label is not a Git checkout: $repo"
        return 0
    fi

    echo ">>> Updating $label"
    git -C "$repo" fetch --prune origin

    local ref
    ref="$(remote_default_ref "$repo")" || {
        echo "WARNING: Could not determine upstream branch for $label."
        return 0
    }

    echo "    upstream: $ref"
    git -C "$repo" reset --hard "$ref"
}

install_repo() {
    local url="$1"
    local dir="$2"
    local path="$COMFYUI_DIR/custom_nodes/$dir"

    echo
    echo ">>> $dir"

    if [ -d "$path/.git" ]; then
        git -C "$path" fetch --prune origin

        local ref
        ref="$(remote_default_ref "$path")" || {
            echo "WARNING: Could not determine upstream branch for $dir; leaving existing checkout."
            return 0
        }

        git -C "$path" reset --hard "$ref"
    elif [ -e "$path" ]; then
        die "$path exists but is not a Git repository. Remove/rename it and rerun."
    else
        git clone "$url" "$path"
    fi
}

filtered_requirements() {
    local source="$1"
    local output="$2"

    # Keep RunPod's working CUDA-enabled torch stack intact.
    grep -vEi '^[[:space:]]*(torch|torchvision|torchaudio)([<>=!~[:space:]].*)?$' \
        "$source" > "$output" || true
}

install_requirements_safe() {
    local req="$1"
    local label="$2"

    if [ ! -f "$req" ]; then
        echo "No requirements.txt: $label"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"

    filtered_requirements "$req" "$tmp"

    if [ -s "$tmp" ]; then
        echo ">>> Installing requirements: $label"
        python -m pip install -r "$tmp"
    else
        echo "No non-Torch requirements to install: $label"
    fi

    rm -f "$tmp"
}

download_hf() {
    local repo="$1"
    local remote_path="$2"
    local destination="$3"
    local revision="${4:-}"
    local basename
    basename="$(basename "$remote_path")"

    mkdir -p "$destination"

    if [ -s "$destination/$basename" ]; then
        echo "Already present: $destination/$basename"
        return 0
    fi

    echo
    echo ">>> Downloading $basename"
    echo "    repo: $repo"

    local tmp
    tmp="$(mktemp -d)"

    if [ -n "$revision" ]; then
        hf download \
            "$repo" \
            "$remote_path" \
            --revision "$revision" \
            --local-dir "$tmp"
    else
        hf download \
            "$repo" \
            "$remote_path" \
            --local-dir "$tmp"
    fi

    [ -s "$tmp/$remote_path" ] || {
        rm -rf "$tmp"
        die "Hugging Face download completed but file was not found: $remote_path"
    }

    mv "$tmp/$remote_path" "$destination/$basename"
    rm -rf "$tmp"
}

# ------------------------------------------------------------
# 1. Update ComfyUI core.
#
# RunPod templates can have a local branch that diverges from
# upstream. A normal 'git pull --ff-only' therefore fails.
# For this disposable bootstrap we intentionally reset tracked
# ComfyUI source files to the current upstream default branch.
#
# This does NOT remove untracked models/custom_nodes.
# ------------------------------------------------------------

log "1/9 - Updating ComfyUI core"

update_git_repo_hard "$COMFYUI_DIR" "ComfyUI"

echo
echo "ComfyUI revision:"
git -C "$COMFYUI_DIR" describe --tags --always 2>/dev/null || \
git -C "$COMFYUI_DIR" rev-parse --short HEAD

# ------------------------------------------------------------
# 2. Update ComfyUI Python requirements WITHOUT replacing Torch.
# ------------------------------------------------------------

log "2/9 - Updating ComfyUI requirements"

install_requirements_safe \
    "$COMFYUI_DIR/requirements.txt" \
    "ComfyUI"

# Verify CUDA immediately.
python - <<'PY'
import sys
import torch

print("Python:", sys.executable)
print("PyTorch:", torch.__version__)
print("Torch CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("ERROR: CUDA is unavailable after ComfyUI dependency update.")

print("GPU:", torch.cuda.get_device_name(0))
PY

# ------------------------------------------------------------
# 3. Update ComfyUI-Manager if the template includes it.
# ------------------------------------------------------------

log "3/9 - Updating ComfyUI-Manager"

MANAGER_DIR="$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"

if [ -d "$MANAGER_DIR/.git" ]; then
    update_git_repo_hard "$MANAGER_DIR" "ComfyUI-Manager"

    if [ -f "$MANAGER_DIR/requirements.txt" ]; then
        install_requirements_safe \
            "$MANAGER_DIR/requirements.txt" \
            "ComfyUI-Manager"
    fi
else
    echo "ComfyUI-Manager Git checkout not found."
    echo "The VNCCS setup itself can still continue because installation is manual."
fi

# ------------------------------------------------------------
# 4. Install/update VNCCS and required custom nodes.
# ------------------------------------------------------------

log "4/9 - Installing VNCCS custom nodes"

mkdir -p "$COMFYUI_DIR/custom_nodes"

install_repo \
    "https://github.com/AHEKOT/ComfyUI_VNCCS.git" \
    "ComfyUI_VNCCS"

install_repo \
    "https://github.com/AHEKOT/ComfyUI_VNCCS_Utils.git" \
    "ComfyUI_VNCCS_Utils"

install_repo \
    "https://github.com/city96/ComfyUI-GGUF.git" \
    "ComfyUI-GGUF"

install_repo \
    "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git" \
    "ComfyUI-Impact-Pack"

install_repo \
    "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git" \
    "ComfyUI-Impact-Subpack"

install_repo \
    "https://github.com/yolain/ComfyUI-Easy-Sam3.git" \
    "ComfyUI-Easy-Sam3"

# ------------------------------------------------------------
# 5. Install custom-node dependencies.
#
# Impact Pack is special:
# its requirements pull facebookresearch/sam2.
# On RunPod, SAM2's isolated build can conflict with the template's
# pinned torch==...+cu128 constraint even though that Torch version
# satisfies SAM2's >=2.5.1 requirement.
#
# So:
#   - install the other nodes normally
#   - install SAM2 with --no-build-isolation
#   - install Impact Pack requirements with the SAM2 line removed
# ------------------------------------------------------------

log "5/9 - Installing custom-node dependencies"

for repo in \
    ComfyUI_VNCCS \
    ComfyUI_VNCCS_Utils \
    ComfyUI-GGUF \
    ComfyUI-Impact-Subpack \
    ComfyUI-Easy-Sam3
do
    install_requirements_safe \
        "$COMFYUI_DIR/custom_nodes/$repo/requirements.txt" \
        "$repo"
done

IMPACT_REQ="$COMFYUI_DIR/custom_nodes/ComfyUI-Impact-Pack/requirements.txt"

if [ -f "$IMPACT_REQ" ]; then
    echo
    echo ">>> Installing SAM2 for Impact Pack without build isolation"

    python -m pip install \
        --no-build-isolation \
        "git+https://github.com/facebookresearch/sam2"

    IMPACT_TMP="$(mktemp)"

    # Remove the SAM2 Git requirement and direct Torch-family requirements.
    grep -vEi 'facebookresearch/sam2' "$IMPACT_REQ" | \
        grep -vEi '^[[:space:]]*(torch|torchvision|torchaudio)([<>=!~[:space:]].*)?$' \
        > "$IMPACT_TMP" || true

    if [ -s "$IMPACT_TMP" ]; then
        echo
        echo ">>> Installing remaining Impact Pack requirements"
        python -m pip install -r "$IMPACT_TMP"
    fi

    rm -f "$IMPACT_TMP"
else
    echo "No requirements.txt: ComfyUI-Impact-Pack"
fi

# Re-check CUDA after all Python dependency installation.
python - <<'PY'
import torch

print("PyTorch after custom nodes:", torch.__version__)
print("Torch CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    raise SystemExit("ERROR: CUDA became unavailable after custom-node installation.")

print("GPU:", torch.cuda.get_device_name(0))
PY

# ------------------------------------------------------------
# 6. Hugging Face downloader.
# ------------------------------------------------------------

log "6/9 - Preparing model downloader"

python -m pip install -U huggingface_hub

command -v hf >/dev/null 2>&1 || \
    die "'hf' CLI not found after installing huggingface_hub."

if [ "$SKIP_MODELS" = "1" ]; then
    echo "SKIP_MODELS=1; custom nodes are installed, model downloads skipped."
    echo
    echo "Restart ComfyUI."
    exit 0
fi

mkdir -p \
    "$COMFYUI_DIR/models/unet" \
    "$COMFYUI_DIR/models/diffusion_models" \
    "$COMFYUI_DIR/models/text_encoders" \
    "$COMFYUI_DIR/models/vae" \
    "$COMFYUI_DIR/models/loras/qwen/VNCCS" \
    "$COMFYUI_DIR/models/loras/Anima" \
    "$COMFYUI_DIR/models/upscale_models"

# ------------------------------------------------------------
# 7. Qwen Image Edit 2511 + VNCCS LoRAs.
# ------------------------------------------------------------

log "7/9 - Downloading QIE2511 ${QIE_QUANT} + VNCCS models"

QIE_FILE="qwen-image-edit-2511-${QIE_QUANT}_0.gguf"

download_hf \
    "unsloth/Qwen-Image-Edit-2511-GGUF" \
    "$QIE_FILE" \
    "$COMFYUI_DIR/models/unet"

download_hf \
    "f5aiteam/CLIP" \
    "qwen_2.5_vl_7b_fp8_scaled.safetensors" \
    "$COMFYUI_DIR/models/text_encoders"

download_hf \
    "Comfy-Org/Qwen-Image_ComfyUI" \
    "split_files/vae/qwen_image_vae.safetensors" \
    "$COMFYUI_DIR/models/vae"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/qwen/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" \
    "$COMFYUI_DIR/models/loras/qwen"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_ClothesCore-RC3.7.safetensors" \
    "$COMFYUI_DIR/models/loras/qwen/VNCCS"

download_hf \
    "MIUProject/VNCCS_PoseStudio" \
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_PoseStudio_ART_V5.9.5.safetensors" \
    "$COMFYUI_DIR/models/loras/qwen/VNCCS"

# ------------------------------------------------------------
# 8. Anima + APISR + native SeedVR2.
#
# VNCCS currently recommends the native SeedVR2 3B FP8 model
# for reduced VRAM use. Its code pins the official SeedVR2 repo
# revision below. We download the matching VAE as well.
# ------------------------------------------------------------

log "8/9 - Downloading Anima, APISR, and SeedVR2"

download_hf \
    "circlestone-labs/Anima" \
    "split_files/diffusion_models/anima-base-v1.0.safetensors" \
    "$COMFYUI_DIR/models/diffusion_models"

download_hf \
    "circlestone-labs/Anima" \
    "split_files/text_encoders/qwen_3_06b_base.safetensors" \
    "$COMFYUI_DIR/models/text_encoders"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/Anima/anima-turbo-lora-v0.1.safetensors" \
    "$COMFYUI_DIR/models/loras/Anima"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/upscale_models/4x_APISR_GRL_GAN_generator.pth" \
    "$COMFYUI_DIR/models/upscale_models"

SEEDVR_REPO="Comfy-Org/SeedVR2"
SEEDVR_REVISION="a457bf495efbd40ea92f699f7d2b5d2febeca176"

download_hf \
    "$SEEDVR_REPO" \
    "seedvr2_3b_fp8_e4m3fn.safetensors" \
    "$COMFYUI_DIR/models/diffusion_models" \
    "$SEEDVR_REVISION"

download_hf \
    "$SEEDVR_REPO" \
    "ema_vae_fp16.safetensors" \
    "$COMFYUI_DIR/models/vae" \
    "$SEEDVR_REVISION"

# ------------------------------------------------------------
# 9. Final verification.
# ------------------------------------------------------------

log "9/9 - Verifying installation"

declare -a REQUIRED_DIRS=(
    "custom_nodes/ComfyUI_VNCCS"
    "custom_nodes/ComfyUI_VNCCS_Utils"
    "custom_nodes/ComfyUI-GGUF"
    "custom_nodes/ComfyUI-Impact-Pack"
    "custom_nodes/ComfyUI-Impact-Subpack"
    "custom_nodes/ComfyUI-Easy-Sam3"
)

declare -a REQUIRED_FILES=(
    "models/unet/$QIE_FILE"
    "models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "models/vae/qwen_image_vae.safetensors"
    "models/loras/qwen/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_ClothesCore-RC3.7.safetensors"
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_PoseStudio_ART_V5.9.5.safetensors"
    "models/diffusion_models/anima-base-v1.0.safetensors"
    "models/text_encoders/qwen_3_06b_base.safetensors"
    "models/loras/Anima/anima-turbo-lora-v0.1.safetensors"
    "models/upscale_models/4x_APISR_GRL_GAN_generator.pth"
    "models/diffusion_models/seedvr2_3b_fp8_e4m3fn.safetensors"
    "models/vae/ema_vae_fp16.safetensors"
)

FAILED=0

for dir in "${REQUIRED_DIRS[@]}"; do
    if [ -d "$COMFYUI_DIR/$dir" ]; then
        printf "OK      %s/\n" "$dir"
    else
        printf "MISSING %s/\n" "$dir"
        FAILED=1
    fi
done

for file in "${REQUIRED_FILES[@]}"; do
    if [ -s "$COMFYUI_DIR/$file" ]; then
        printf "OK      %s\n" "$file"
    else
        printf "MISSING %s\n" "$file"
        FAILED=1
    fi
done

echo
python - <<'PY'
import torch
print("Final PyTorch:", torch.__version__)
print("Final CUDA runtime:", torch.version.cuda)
print("Final CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("Final GPU:", torch.cuda.get_device_name(0))
PY

echo

if [ "$FAILED" -ne 0 ]; then
    die "Installation finished with missing components. Review the output above."
fi

echo "============================================================"
echo " VNCCS installation complete."
echo
echo " Restart ComfyUI completely before opening VNCCS."
echo
echo " QIE quantization: $QIE_QUANT"
echo " SeedVR2:          3B FP8 native"
echo "============================================================"

