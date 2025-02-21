# Stage 1: Base image with common dependencies
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 as base

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1 
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools plus additional dependencies for custom nodes
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    git \
    wget \
    libgl1 \
    ffmpeg \
    libzbar0 \
    libopencv-dev \
    python3-opencv \
    build-essential \
    cmake \
    && ln -sf /usr/bin/python3.10 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Copy snapshot file early to use for pip installations
COPY 2025-02-21_17-25-15_snapshot.json /

# Install pip dependencies from snapshot
RUN pip install --no-cache-dir $(python3 -c "import json; print(' '.join([k for k, v in json.load(open('/2025-02-21_17-25-15_snapshot.json'))['pips'].items() if not v.startswith('git+')]))")

# Handle git dependencies separately
RUN pip install git+https://github.com/openai/swarm.git@9db581cecaacea0d46a933d6453c312b034dbf47

# Additional dependencies for specific nodes
RUN pip install --no-cache-dir \
    segment-anything-pt2 \
    opencv-contrib-python --upgrade \
    ultralytics \
    supervision \
    mediapipe

# Install comfy-cli
RUN pip install comfy-cli

# Install ComfyUI
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.2.7

# Change working directory to ComfyUI
WORKDIR /comfyui

# Install runpod
RUN pip install runpod requests

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Add scripts
ADD src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json ./
RUN chmod +x /start.sh /restore_snapshot.sh

# Restore the snapshot to install custom nodes
RUN /restore_snapshot.sh

# Start container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base as downloader
ARG HUGGINGFACE_ACCESS_TOKEN
ARG MODEL_TYPE

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create all necessary directories
RUN mkdir -p \
    models/checkpoints \
    models/vae \
    models/clip \
    models/unet \
    models/yolo \
    models/controlnet \
    models/sam \
    models/clip_interrogator \
    models/prompt_generator \
    models/segment_anything \
    models/depth_anything

# Download FLUX models if specified
RUN if [ "$MODEL_TYPE" = "flux1-schnell" ]; then \
      wget -O models/unet/flux1-schnell.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors && \
      wget -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
    fi

# YOLO models
RUN wget -O models/yolo/yolov8n.pt https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.pt

# ControlNet models
RUN wget -O models/controlnet/hand_pose_model.pth https://huggingface.co/hr16/ControlNet-HandPose-Annotator/resolve/main/hand_pose_model.pth && \
    wget -O models/controlnet/dw-ll_ucoco_384.onnx https://huggingface.co/hr16/ControlNet-HandPose-Annotator/resolve/main/dw-ll_ucoco_384.onnx

# SAM2 models
RUN wget -O models/sam/sam2_b.pth https://dl.fbaipublicfiles.com/segment_anything/sam2/sam2_b.pth

# Clip Interrogator and Prompt Generator models
RUN wget -O models/clip_interrogator/blip-image-captioning-base.pth https://huggingface.co/Salesforce/blip-image-captioning-base/resolve/main/pytorch_model.bin || true
RUN wget -O models/prompt_generator/text2image-prompt-generator.pth https://huggingface.co/succinctly/text2image-prompt-generator/resolve/main/pytorch_model.bin || true

# Depth Anything models
RUN wget -O models/depth_anything/depth_anything_vitl14.pth https://huggingface.co/LiheYoung/depth_anything/resolve/main/depth_anything_vitl14.pth

# Additional models for other nodes that might need them
RUN wget -O models/sam/sam_vit_h_4b8939.pth https://dl.fbaipublicfiles.com/segment_anything/sam_vit_h_4b8939.pth || true

# Stage 3: Final image
FROM base as final

# Copy models from stage 2 to the final image
COPY --from=downloader /comfyui/models /comfyui/models

# Start container
CMD ["/start.sh"]
