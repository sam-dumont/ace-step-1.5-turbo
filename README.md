# ACE-Step 1.5 Docker Image (Turbo + 0.6B LM)

Fork of [ValyrianTech/ace-step-1.5](https://github.com/ValyrianTech/ace-step-1.5) optimized for GPUs with 8GB VRAM.

The upstream image ships the **base** DiT model (50 diffusion steps) and the **1.7B** language model. That's fine if you have 32GB+ VRAM, but on an 8GB card like a T1000 or GTX 1070, you'll either OOM or wait forever.

This fork swaps in:

- **Turbo DiT model** (`acestep-v15-turbo`): 8 diffusion steps instead of 50, roughly 6x faster with minimal quality loss
- **0.6B LM** (`acestep-5Hz-lm-0.6B`): saves ~2.2GB VRAM compared to the 1.7B, still provides semantic planning ("thinking mode")

The base model and 1.7B LM are excluded from the image entirely to keep it smaller.

## What changed from upstream

3 files, all straightforward:

**Dockerfile:**
- Main model download now excludes `acestep-v15-base/*` and `acestep-5Hz-lm-1.7B/*` (upstream excludes turbo instead)
- Downloads `ACE-Step/acestep-5Hz-lm-0.6B` separately
- `ACESTEP_CONFIG_PATH` points to turbo, `ACESTEP_LM_MODEL_PATH` points to 0.6B
- Placeholder directory flipped from turbo to base (the startup check wants both dirs to exist)

**start.sh:**
- Defaults updated to match: turbo DiT + 0.6B LM

That's it. Everything else (API server, Gradio UI, endpoints) is identical to upstream.

## Hardware notes

Tested on an NVIDIA T1000 8GB (Turing, SM 75). Key constraints for this class of GPU:

- No bf16 support (Ampere+ only), runs in FP16
- No Flash Attention (SM 80+ only), must use `pt` backend instead of `vllm`
- INT8 quantization and CPU offloading auto-enabled by ACE-Step's tier detection
- ACE-Step caps generation at ~60 seconds with LM enabled at this VRAM tier

For even less VRAM usage, you can disable the LM entirely with `ACESTEP_INIT_LLM=false` (cuts VRAM to under 5GB, 30-50% faster, but loses the lyrics enhancement feature).

## Quick Start

### Prerequisites

- Docker with NVIDIA Container Toolkit
- NVIDIA GPU with CUDA support
- HuggingFace token (for downloading gated models during build)

### Build

```bash
docker build --build-arg HF_TOKEN=YOUR_HF_TOKEN -t acestep-api:latest .
```

### Run

```bash
docker compose up -d
```

API available at `http://localhost:8000`.

## CLI Tool

```bash
python generate_music.py \
  --api-url http://localhost:8000 \
  --caption "Upbeat indie pop with jangly guitars and energetic vocals" \
  --lyrics "[Verse 1]\nWalking down the street\nMusic in my feet\n\n[Chorus]\nWe are alive tonight" \
  --duration 90 \
  --output my_song.mp3
```

Handles task submission, polling, and file download automatically. See `python generate_music.py --help` for all options.

## API Endpoints

See the [ACE-Step API documentation](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/API.md) for full details.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/v1/models` | GET | List available models |
| `/release_task` | POST | Create music generation task |
| `/query_result` | POST | Batch query task results |
| `/format_input` | POST | Format and enhance lyrics/caption via LLM |
| `/v1/audio` | GET | Download audio file |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ACESTEP_CONFIG_PATH` | `/app/checkpoints/acestep-v15-turbo` | Path to DiT model |
| `ACESTEP_LM_MODEL_PATH` | `/app/checkpoints/acestep-5Hz-lm-0.6B` | Path to LM model |
| `ACESTEP_OUTPUT_DIR` | `/app/outputs` | Generated audio output directory |
| `ACESTEP_DEVICE` | `cuda` | Device (cuda, cpu, mps) |
| `ACESTEP_LM_BACKEND` | `pt` | LLM backend (vllm, pt) |
| `ACESTEP_API_HOST` | `0.0.0.0` | Server host |
| `ACESTEP_API_PORT` | `8000` | Server port |
| `ACESTEP_INIT_LLM` | `true` | Set to `false` to disable LM entirely |

## License

See the [ACE-Step 1.5 repository](https://github.com/ace-step/ACE-Step-1.5) for license information.
