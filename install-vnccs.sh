#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# VNCCS RunPod Setup
#
# Assumes:
#   - A working ComfyUI installation already exists
#   - ComfyUI has its own Python virtual environment
#   - git is installed
#
# Tested with:
#   - RunPod
#   - NVIDIA RTX 4090
#   - ComfyUI
#   - Qwen Image Edit 2511 GGUF Q8
# ============================================================

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"

echo "============================================"
echo " VNCCS RunPod Setup"
echo "============================================"
echo
echo "ComfyUI directory: $COMFYUI_DIR"
echo

# ------------------------------------------------------------
# Validate ComfyUI
# ------------------------------------------------------------

if [ ! -f "$COMFYUI_DIR/main.py" ]; then
    echo "ERROR: ComfyUI main.py not found:"
    echo "  $COMFYUI_DIR/main.py"
    echo
    echo "Set COMFYUI_DIR manually if necessary:"
    echo "  COMFYUI_DIR=/path/to/ComfyUI ./install-vnccs.sh"
    exit 1
fi

cd "$COMFYUI_DIR"

# ------------------------------------------------------------
# Detect virtual environment
# ------------------------------------------------------------

VENV=""

for candidate in \
    ".venv-cu128" \
    ".venv" \
    "venv"
do
    if [ -x "$candidate/bin/python" ]; then
        VENV="$candidate"
        break
    fi
done

if [ -z "$VENV" ]; then
    echo "ERROR: Could not find ComfyUI Python environment."
    echo
    echo "Expected one of:"
    echo "  .venv-cu128"
    echo "  .venv"
    echo "  venv"
    exit 1
fi

echo "Using Python environment: $VENV"

source "$VENV/bin/activate"

# ------------------------------------------------------------
# Update ComfyUI core
# ------------------------------------------------------------

echo
echo "============================================"
echo " Updating ComfyUI"
echo "============================================"

cd "$COMFYUI_DIR"

if [ -d ".git" ]; then
    git fetch origin

    CURRENT_BRANCH="$(git branch --show-current)"

    if [ -n "$CURRENT_BRANCH" ]; then
        git pull --ff-only origin "$CURRENT_BRANCH"
    else
        echo "WARNING: ComfyUI is in detached HEAD state; skipping automatic pull."
    fi
else
    echo "WARNING: ComfyUI is not a Git repository; skipping core update."
fi

# ------------------------------------------------------------
# Update ComfyUI-Manager
# ------------------------------------------------------------

echo
echo "============================================"
echo " Updating ComfyUI-Manager"
echo "============================================"

MANAGER_DIR="$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"

if [ -d "$MANAGER_DIR/.git" ]; then
    git -C "$MANAGER_DIR" fetch origin

    MANAGER_BRANCH="$(git -C "$MANAGER_DIR" branch --show-current)"

    if [ -n "$MANAGER_BRANCH" ]; then
        git -C "$MANAGER_DIR" pull --ff-only origin "$MANAGER_BRANCH"
    else
        echo "WARNING: ComfyUI-Manager is in detached HEAD state."
    fi
else
    echo "ComfyUI-Manager Git repository not found; leaving template installation untouched."
fi

echo
echo "============================================"
echo " Checking ComfyUI environment"
echo "============================================"

python - <<'PY'
import torch

print("PyTorch:", torch.__version__)
print("CUDA runtime:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
PY

echo "Python: $(which python)"
python --version

# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------

mkdir -p custom_nodes
mkdir -p models/unet
mkdir -p models/diffusion_models
mkdir -p models/text_encoders
mkdir -p models/vae
mkdir -p models/loras/qwen/VNCCS
mkdir -p models/loras/Anima
mkdir -p models/upscale_models

# ------------------------------------------------------------
# Helper: clone/update repository
# ------------------------------------------------------------

install_repo() {
    local url="$1"
    local dir="$2"

    echo
    echo ">>> $dir"

    if [ -d "custom_nodes/$dir/.git" ]; then
        echo "Already installed. Updating..."
        git -C "custom_nodes/$dir" pull --ff-only || \
            echo "WARNING: Could not update $dir"
    elif [ -e "custom_nodes/$dir" ]; then
        echo "WARNING: custom_nodes/$dir exists but is not a Git repository."
        echo "Skipping to avoid deleting existing data."
    else
        git clone "$url" "custom_nodes/$dir"
    fi
}

# ------------------------------------------------------------
# VNCCS
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing VNCCS custom nodes"
echo "============================================"

install_repo \
    "https://github.com/AHEKOT/ComfyUI_VNCCS.git" \
    "ComfyUI_VNCCS"

install_repo \
    "https://github.com/AHEKOT/ComfyUI_VNCCS_Utils.git" \
    "ComfyUI_VNCCS_Utils"

# ------------------------------------------------------------
# Required VNCCS dependencies
# ------------------------------------------------------------

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
# Custom-node Python requirements
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing custom-node requirements"
echo "============================================"

for repo in \
    ComfyUI_VNCCS \
    ComfyUI_VNCCS_Utils \
    ComfyUI-GGUF \
    ComfyUI-Impact-Subpack \
    ComfyUI-Easy-Sam3
do
    REQUIREMENTS="custom_nodes/$repo/requirements.txt"

    if [ -f "$REQUIREMENTS" ]; then
        echo
        echo ">>> $repo requirements"
        python -m pip install -r "$REQUIREMENTS"
    fi
done

# Impact Pack needs facebookresearch/sam2.
# RunPod pins PyTorch, and SAM2's isolated build environment can conflict
# with that constraint even though the installed torch version is compatible.

echo
echo ">>> Installing SAM2 for Impact Pack"

python -m pip install \
    --no-build-isolation \
    "git+https://github.com/facebookresearch/sam2"

echo
echo ">>> Installing Impact Pack requirements"

grep -v 'facebookresearch/sam2' \
    custom_nodes/ComfyUI-Impact-Pack/requirements.txt \
    > /tmp/impact-pack-requirements.txt

python -m pip install -r /tmp/impact-pack-requirements.txt

rm -f /tmp/impact-pack-requirements.txt

# ------------------------------------------------------------
# Hugging Face CLI
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing Hugging Face CLI"
echo "============================================"

python -m pip install -U huggingface_hub

if ! command -v hf >/dev/null 2>&1; then
    echo "ERROR: hf CLI is unavailable."
    exit 1
fi

# ------------------------------------------------------------
# Helper: Hugging Face download
# ------------------------------------------------------------

download_hf() {
    local repo="$1"
    local filename="$2"
    local destination="$3"

    mkdir -p "$destination"

    local basename
    basename="$(basename "$filename")"

    if [ -f "$destination/$basename" ]; then
        echo "Already downloaded: $destination/$basename"
        return
    fi

    echo
    echo ">>> Downloading $basename"

    local temp_dir
    temp_dir="$(mktemp -d)"

    hf download \
        "$repo" \
        "$filename" \
        --local-dir "$temp_dir"

    local downloaded="$temp_dir/$filename"

    if [ ! -f "$downloaded" ]; then
        echo "ERROR: Downloaded file not found:"
        echo "  $downloaded"
        rm -rf "$temp_dir"
        exit 1
    fi

    mv "$downloaded" "$destination/$basename"
    rm -rf "$temp_dir"
}

# ------------------------------------------------------------
# Qwen Image Edit 2511 - Q8
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing QIE2511 Q8"
echo "============================================"

download_hf \
    "unsloth/Qwen-Image-Edit-2511-GGUF" \
    "qwen-image-edit-2511-Q8_0.gguf" \
    "models/unet"

download_hf \
    "f5aiteam/CLIP" \
    "qwen_2.5_vl_7b_fp8_scaled.safetensors" \
    "models/text_encoders"

# Qwen VAE

if [ ! -f "models/vae/qwen_image_vae.safetensors" ]; then
    TMP="$(mktemp -d)"

    hf download \
        "Comfy-Org/Qwen-Image_ComfyUI" \
        "split_files/vae/qwen_image_vae.safetensors" \
        --local-dir "$TMP"

    mv \
        "$TMP/split_files/vae/qwen_image_vae.safetensors" \
        "models/vae/qwen_image_vae.safetensors"

    rm -rf "$TMP"
else
    echo "Already downloaded: Qwen Image VAE"
fi

# ------------------------------------------------------------
# QIE2511 LoRAs
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing QIE2511 LoRAs"
echo "============================================"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/qwen/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" \
    "models/loras/qwen"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_ClothesCore-RC3.7.safetensors" \
    "models/loras/qwen/VNCCS"

download_hf \
    "MIUProject/VNCCS_PoseStudio" \
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_PoseStudio_ART_V5.9.5.safetensors" \
    "models/loras/qwen/VNCCS"

# ------------------------------------------------------------
# Anima
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing Anima"
echo "============================================"

download_hf \
    "circlestone-labs/Anima" \
    "split_files/diffusion_models/anima-base-v1.0.safetensors" \
    "models/diffusion_models"

download_hf \
    "circlestone-labs/Anima" \
    "split_files/text_encoders/qwen_3_06b_base.safetensors" \
    "models/text_encoders"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/loras/Anima/anima-turbo-lora-v0.1.safetensors" \
    "models/loras/Anima"

# ------------------------------------------------------------
# APISR GAN upscaler
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installing APISR upscaler"
echo "============================================"

download_hf \
    "MIUProject/VNCCS_v3.0" \
    "models/upscale_models/4x_APISR_GRL_GAN_generator.pth" \
    "models/upscale_models"

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "============================================"
echo " Installation summary"
echo "============================================"

FILES=(
    "models/unet/qwen-image-edit-2511-Q8_0.gguf"
    "models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
    "models/vae/qwen_image_vae.safetensors"
    "models/loras/qwen/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_ClothesCore-RC3.7.safetensors"
    "models/loras/qwen/VNCCS/VNCCS_QIE2511_PoseStudio_ART_V5.9.5.safetensors"
    "models/diffusion_models/anima-base-v1.0.safetensors"
    "models/text_encoders/qwen_3_06b_base.safetensors"
    "models/loras/Anima/anima-turbo-lora-v0.1.safetensors"
    "models/upscale_models/4x_APISR_GRL_GAN_generator.pth"
)

FAILED=0

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        printf "OK      %s\n" "$file"
    else
        printf "MISSING %s\n" "$file"
        FAILED=1
    fi
done

echo

if [ "$FAILED" -eq 0 ]; then
    echo "============================================"
    echo " VNCCS installation complete."
    echo " Restart ComfyUI before using VNCCS."
    echo "============================================"
else
    echo "WARNING: Some files are missing."
    exit 1
fi
