# syntax=docker/dockerfile:1

# Multi-stage build for authenticated model downloads
FROM python:3.10-slim AS model-downloader
# Install huggingface-cli
RUN pip install huggingface_hub
# Set working directory
WORKDIR /model-downloader
# Create directory for downloaded models
RUN mkdir -p /model-downloader/models/csm-1b
RUN mkdir -p /model-downloader/models/dia-1.6b

# This will run when building the image
# You'll need to pass your Hugging Face token at build time
ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}
ARG TTS_ENGINE=csm

# Login with token if provided
RUN if [ -n "$HF_TOKEN" ]; then \
    huggingface-cli login --token ${HF_TOKEN}; \
    fi

# Download CSM-1B model (only if token provided)
RUN if [ -n "$HF_TOKEN" ]; then \
    echo "Downloading CSM-1B model..."; \
    huggingface-cli download sesame/csm-1b ckpt.pt --local-dir /model-downloader/models/csm-1b; \
    else echo "Skipping CSM-1B model download (no HF_TOKEN)"; fi

# Download Dia-1.6B model (only if token provided)
RUN if [ -n "$HF_TOKEN" ]; then \
    echo "Downloading Dia-1.6B model..."; \
    huggingface-cli download nari-labs/Dia-1.6B config.json --local-dir /model-downloader/models/dia-1.6b; \
    huggingface-cli download nari-labs/Dia-1.6B dia-v0_1.pth --local-dir /model-downloader/models/dia-1.6b; \
    else echo "Skipping Dia-1.6B model download (no HF_TOKEN)"; fi

# Now for the main application stage (ROCm)
FROM python:3.10-slim
# Set environment variables (ROCm-friendly)
ENV PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=100 \
    ROCM_PATH=/opt/rocm \
    HSA_OVERRIDE_GFX_VERSION=10.3.0

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    git \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY requirements.txt .
COPY requirements-dia.txt .

# Create and set up persistent directories with proper permissions
RUN mkdir -p /app/static /app/models /app/models/csm-1b /app/models/dia-1.6b \
    /app/voice_memories /app/voice_references /app/voice_profiles \
    /app/cloned_voices /app/audio_cache /app/tokenizers /app/logs && \
    chmod -R 777 /app/voice_references /app/voice_profiles /app/voice_memories \
    /app/cloned_voices /app/audio_cache /app/static /app/logs /app/tokenizers /app/models

# Copy static files
COPY ./static /app/static

# Upgrade pip (dependencies installed later from requirements.txt)
RUN pip3 install --no-cache-dir --upgrade pip

# Install base requirements
RUN pip3 install -r requirements.txt


# Install Dia model dependencies if TTS_ENGINE is set to dia
ARG TTS_ENGINE=csm
RUN if [ "$TTS_ENGINE" = "dia" ]; then \
    echo "Installing Dia model dependencies..." && \
    pip3 install -r requirements-dia.txt && \
    echo "Dia model dependencies installed"; \
fi


# Copy application code
COPY ./app /app/app

# Copy downloaded models from the model-downloader stage
COPY --from=model-downloader /model-downloader/models/csm-1b /app/models/csm-1b
COPY --from=model-downloader /model-downloader/models/dia-1.6b /app/models/dia-1.6b

# Show available models in torchtune
RUN python3 -c "import torchtune.models; print('Available models in torchtune:', dir(torchtune.models))"

# Expose port
EXPOSE 8000

# Command to run the application
CMD ["python3", "-m", "app.main"]
