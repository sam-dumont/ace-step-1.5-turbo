# =============================================================================
# ACE-Step 1.5 FastAPI Server - Multi-stage Dockerfile
# =============================================================================
# This image includes the ACE-Step models (~15GB total)
# Build with: docker build --secret id=HF_TOKEN,env=HF_TOKEN -t acestep-api:latest .
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Model Downloader - Download models from HuggingFace
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS model-downloader

WORKDIR /models

# Install huggingface-hub with hf_transfer for faster downloads
RUN pip install --no-cache-dir "huggingface-hub[cli,hf_transfer]"

# Enable fast transfers
ENV HF_HUB_ENABLE_HF_TRANSFER=1

# Download main model package (shared components: VAE, Qwen3-Embedding, text encoder)
# The main package includes directory stubs for all variants but NOT the actual DiT weights.
# DiT weights and LM models must be downloaded separately from their own HF repos.
RUN --mount=type=secret,id=HF_TOKEN \
    python -c "from huggingface_hub import snapshot_download; token=open('/run/secrets/HF_TOKEN').read().strip(); snapshot_download('ACE-Step/Ace-Step1.5', local_dir='/models/checkpoints', token=token)"

# Download turbo DiT model weights (8 diffusion steps, ~6x faster than base)
RUN --mount=type=secret,id=HF_TOKEN \
    python -c "from huggingface_hub import snapshot_download; token=open('/run/secrets/HF_TOKEN').read().strip(); snapshot_download('ACE-Step/acestep-v15-turbo', local_dir='/models/checkpoints/acestep-v15-turbo', token=token)"

# Download 0.6B LM — fits comfortably in 8GB VRAM alongside the DiT and VAE
RUN --mount=type=secret,id=HF_TOKEN \
    python -c "from huggingface_hub import snapshot_download; token=open('/run/secrets/HF_TOKEN').read().strip(); snapshot_download('ACE-Step/acestep-5Hz-lm-0.6B', local_dir='/models/checkpoints/acestep-5Hz-lm-0.6B', token=token)"

# -----------------------------------------------------------------------------
# Stage 2: Runtime - Install ACE-Step and run from /app
# -----------------------------------------------------------------------------
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04 AS runtime

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    # ACE-Step configuration
    ACESTEP_PROJECT_ROOT=/app \
    ACESTEP_OUTPUT_DIR=/app/outputs \
    ACESTEP_TMPDIR=/app/outputs \
    ACESTEP_DEVICE=cuda \
    # ACE-Step API model paths (full paths to pre-baked models)
    ACESTEP_CONFIG_PATH=/app/checkpoints/acestep-v15-turbo \
    ACESTEP_LM_MODEL_PATH=/app/checkpoints/acestep-5Hz-lm-0.6B \
    ACESTEP_LM_BACKEND=pt \
    # Server configuration
    ACESTEP_API_HOST=0.0.0.0 \
    ACESTEP_API_PORT=8000

WORKDIR /app

# Install system dependencies including Python, pip, git, and build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3-pip \
    git \
    curl \
    build-essential \
    libsndfile1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/bin/python

# Install uv for faster dependency resolution
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# Clone ACE-Step directly into /app and install
RUN git clone https://github.com/ace-step/ACE-Step-1.5.git /app && \
    rm -rf /app/.git && \
    uv pip install --system --no-cache .

# Create symlink so ACE-Step's model discovery finds /app/checkpoints
# ACE-Step uses __file__ to locate checkpoints relative to its install path
RUN ln -s /app/checkpoints /usr/local/lib/python3.11/dist-packages/checkpoints

# Copy models from model-downloader stage into /app/checkpoints
COPY --from=model-downloader /models/checkpoints /app/checkpoints

# Create non-root user (UID 1001) and fix ownership
RUN groupadd -g 1001 appuser && \
    useradd -u 1001 -g 1001 -m -s /bin/bash appuser

# Copy startup script
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Fix ownership for all dirs ACE-Step writes to at runtime:
#   /app/outputs        — generated audio, logs
#   /app/checkpoints    — model checkpoints (symlinked into site-packages)
#   /home/appuser/.cache — PyTorch/HF cache
#   site-packages/      — ACE-Step creates gradio_outputs/, .cache/, and other
#                         dirs inside its install path at import time. Rather than
#                         chasing each one, make the entire dist-packages tree
#                         writable by appuser.
RUN mkdir -p /app/outputs /home/appuser/.cache && \
    chown -R 1001:1001 /app/outputs /app/checkpoints /home/appuser/.cache \
    /usr/local/lib/python3.11/dist-packages

# PyTorch cache dir: getpass.getuser() needs the user in /etc/passwd (done above),
# and the cache dir must be writable by UID 1001
ENV TORCHINDUCTOR_CACHE_DIR=/home/appuser/.cache/torch_inductor

# Expose ports (8000 for API, 7860 for Gradio UI)
EXPOSE 8000 7860

USER 1001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Run both API server and Gradio UI
CMD ["/app/start.sh"]
