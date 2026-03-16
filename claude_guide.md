# Building a RunPod Serverless Load Balancer Worker with llama.cpp

A complete guide to deploying llama.cpp as a RunPod Serverless **load balancer** endpoint — bypassing the queue system for low-latency, OpenAI-compatible LLM inference.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Understanding Load Balancer vs. Queue-Based Endpoints](#3-understanding-load-balancer-vs-queue-based-endpoints)
4. [Project Structure](#4-project-structure)
5. [The Health-Check Proxy (FastAPI)](#5-the-health-check-proxy-fastapi)
6. [Startup Script](#6-startup-script)
7. [Dockerfile](#7-dockerfile)
8. [Model Delivery Strategy](#8-model-delivery-strategy)
9. [Building and Pushing the Docker Image](#9-building-and-pushing-the-docker-image)
10. [Deploying to RunPod](#10-deploying-to-runpod)
11. [Testing Your Endpoint](#11-testing-your-endpoint)
12. [Tuning llama.cpp Server Parameters](#12-tuning-llamacpp-server-parameters)
13. [Scaling and Cost Strategy](#13-scaling-and-cost-strategy)
14. [Troubleshooting](#14-troubleshooting)
15. [Complete File Listing](#15-complete-file-listing)

---

## 1. Architecture Overview

```
Client (curl / OpenAI SDK / your app)
        │
        ▼
RunPod Load Balancer  ──────────────────────────────────────
        │  routes directly to an available worker (no queue)
        ▼
┌─────────────────────────────────────────────────────┐
│  Worker Container                                   │
│                                                     │
│   start.sh                                          │
│     ├── launches llama-server on port 8080          │
│     └── launches FastAPI health proxy on port 3000  │
│                                                     │
│   FastAPI proxy (port 3000)                         │
│     └── /ping  →  checks llama-server /health       │
│         returns 204 while loading, 200 when ready   │
│                                                     │
│   llama-server (port 8080)                          │
│     ├── /v1/chat/completions  (OpenAI-compatible)   │
│     ├── /v1/completions                             │
│     ├── /v1/embeddings                              │
│     ├── /v1/models                                  │
│     ├── /health                                     │
│     └── /completion  (native llama.cpp endpoint)    │
└─────────────────────────────────────────────────────┘
```

RunPod's load balancer needs a `/ping` endpoint on a dedicated health port (`PORT_HEALTH`) that returns:

- **200** — worker is healthy and ready to accept traffic
- **204** — worker is still initializing (loading model)
- Anything else — worker is unhealthy, removed from the pool

llama.cpp's built-in `/health` endpoint returns `{ "status": "loading model" }` or `{ "status": "ok" }`, so we use a thin FastAPI proxy to translate that into the status codes RunPod expects.

All inference traffic flows directly to the llama-server on `PORT` (8080), giving you the full OpenAI-compatible API without any translation layer.

---

## 2. Prerequisites

- **RunPod account** with funds loaded (serverless is pay-per-second)
- **RunPod API key** (Settings → API Keys in the RunPod console)
- **Docker** installed locally (Docker Desktop or Docker Engine)
- **Docker Hub account** (or any container registry: GitHub Container Registry, etc.)
- A **GGUF model file** — either hosted on Hugging Face or uploaded to a RunPod Network Volume

---

## 3. Understanding Load Balancer vs. Queue-Based Endpoints

RunPod Serverless offers two endpoint types. This guide targets **Load Balancer**.

| Aspect | Load Balancer | Queue-Based |
|---|---|---|
| **Request flow** | Direct to worker HTTP server | Through RunPod's queueing system |
| **Implementation** | Custom HTTP server (FastAPI, Flask, llama-server, etc.) | `runpod.serverless.start({"handler": fn})` |
| **API paths** | Fully custom — you define all routes | Fixed `/run` and `/runsync` only |
| **Backpressure** | Drops requests when all workers are busy | Queues requests, processes in order |
| **Latency** | Lower (single hop, direct to worker) | Higher (queue → worker → response) |
| **Retries** | No built-in retry; implement client-side | Automatic retries built in |
| **Streaming** | Native HTTP streaming supported | Requires special handling |
| **Best for** | Real-time chat, streaming completions, OpenAI-compatible APIs | Batch jobs, async processing, guaranteed delivery |

**Why Load Balancer for llama.cpp?** llama-server is already a full HTTP server with OpenAI-compatible endpoints and built-in request batching. Wrapping it in RunPod's queue handler would add unnecessary latency and prevent direct streaming. The load balancer approach lets clients talk to llama-server natively.

---

## 4. Project Structure

```
runpod-llamacpp-lb/
├── Dockerfile
├── health_proxy.py      # FastAPI health-check proxy
├── start.sh             # Entrypoint script
└── README.md
```

The design is intentionally minimal. llama-server handles all inference; the only custom code is a small health proxy that translates llama.cpp's health status into RunPod's expected status codes.

---

## 5. The Health-Check Proxy (FastAPI)

RunPod's load balancer pings `/ping` on the `PORT_HEALTH` port. This tiny FastAPI app checks whether llama-server is ready and returns the appropriate status code.

### `health_proxy.py`

```python
"""
Health-check proxy for RunPod Load Balancer + llama.cpp

RunPod load balancer expects:
  GET /ping  →  200 = healthy, 204 = initializing, other = unhealthy

llama-server exposes:
  GET /health  →  {"status": "ok"} or {"status": "loading model"} etc.

This proxy bridges the two.
"""

import os
import httpx
from fastapi import FastAPI, Response

app = FastAPI()

LLAMA_SERVER_HOST = os.getenv("LLAMA_SERVER_HOST", "127.0.0.1")
LLAMA_SERVER_PORT = os.getenv("LLAMA_SERVER_PORT", "8080")
LLAMA_HEALTH_URL = f"http://{LLAMA_SERVER_HOST}:{LLAMA_SERVER_PORT}/health"


@app.get("/ping")
async def ping():
    """
    Health check endpoint for RunPod load balancer.

    Returns:
        200 - llama-server is loaded and ready
        204 - llama-server is still loading the model
        503 - llama-server is unreachable or errored
    """
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(LLAMA_HEALTH_URL)

        if resp.status_code == 200:
            data = resp.json()
            status = data.get("status", "")

            if status == "ok":
                return Response(
                    content='{"status": "healthy"}',
                    media_type="application/json",
                    status_code=200,
                )
            elif status in ("loading model", "no slot available"):
                # Model still loading — tell RunPod we're initializing
                return Response(
                    content='{"status": "initializing"}',
                    media_type="application/json",
                    status_code=204,
                )
            else:
                # Unknown status — report as initializing to be safe
                return Response(
                    content='{"status": "initializing"}',
                    media_type="application/json",
                    status_code=204,
                )
        else:
            return Response(status_code=503)

    except Exception:
        # llama-server not reachable yet — still starting up
        return Response(
            content='{"status": "initializing"}',
            media_type="application/json",
            status_code=204,
        )


if __name__ == "__main__":
    import uvicorn

    health_port = int(os.getenv("PORT_HEALTH", "3000"))
    print(f"[health_proxy] Starting on port {health_port}")
    uvicorn.run(app, host="0.0.0.0", port=health_port)
```

**Key design decisions:**

- If llama-server is unreachable (still starting), we return 204 (initializing) rather than an error. This prevents RunPod from marking the worker as unhealthy during normal startup.
- The `"no slot available"` status means all inference slots are busy — we treat that as initializing so the worker isn't killed.
- We use `httpx` for async HTTP to avoid blocking the event loop.

---

## 6. Startup Script

The entrypoint script launches both llama-server and the health proxy. llama-server runs as the main process; the health proxy runs in the background.

### `start.sh`

```bash
#!/bin/bash
set -e

# =============================================================================
# RunPod Load Balancer + llama.cpp  —  Startup Script
# =============================================================================

# --- Configuration via environment variables ---
# MODEL_PATH        : Path to the GGUF file inside the container
#                     (default: /models/model.gguf)
# MODEL_HF_REPO     : Hugging Face repo to download from (e.g., "bartowski/Qwen3-30B-A3B-GGUF")
# MODEL_HF_FILE     : Specific file in the repo (e.g., "Qwen3-30B-A3B-Q4_K_M.gguf")
# N_GPU_LAYERS       : Number of layers to offload to GPU (-1 = all)  (default: -1)
# CTX_SIZE           : Context size in tokens                         (default: 8192)
# N_PARALLEL         : Number of parallel inference slots              (default: 4)
# PORT               : llama-server port (RunPod sends traffic here)   (default: 8080)
# PORT_HEALTH        : Health-check proxy port                         (default: 3000)
# LLAMA_EXTRA_ARGS   : Any additional llama-server arguments           (default: "")

MODEL_PATH="${MODEL_PATH:-/models/model.gguf}"
N_GPU_LAYERS="${N_GPU_LAYERS:--1}"
CTX_SIZE="${CTX_SIZE:-8192}"
N_PARALLEL="${N_PARALLEL:-4}"
MAIN_PORT="${PORT:-8080}"
HEALTH_PORT="${PORT_HEALTH:-3000}"

echo "============================================"
echo "  RunPod llama.cpp Load Balancer Worker"
echo "============================================"
echo "  MODEL_PATH     : ${MODEL_PATH}"
echo "  MODEL_HF_REPO  : ${MODEL_HF_REPO:-<not set>}"
echo "  MODEL_HF_FILE  : ${MODEL_HF_FILE:-<not set>}"
echo "  N_GPU_LAYERS   : ${N_GPU_LAYERS}"
echo "  CTX_SIZE       : ${CTX_SIZE}"
echo "  N_PARALLEL     : ${N_PARALLEL}"
echo "  PORT (main)    : ${MAIN_PORT}"
echo "  PORT_HEALTH    : ${HEALTH_PORT}"
echo "============================================"

# --- Download model from HuggingFace if needed ---
if [ -n "${MODEL_HF_REPO}" ] && [ ! -f "${MODEL_PATH}" ]; then
    echo "[startup] Downloading model from HuggingFace..."
    if [ -n "${MODEL_HF_FILE}" ]; then
        echo "[startup]   Repo: ${MODEL_HF_REPO}"
        echo "[startup]   File: ${MODEL_HF_FILE}"

        mkdir -p "$(dirname "${MODEL_PATH}")"

        # Use huggingface-cli if available, otherwise curl
        if command -v huggingface-cli &> /dev/null; then
            huggingface-cli download "${MODEL_HF_REPO}" "${MODEL_HF_FILE}" \
                --local-dir "$(dirname "${MODEL_PATH}")" \
                --local-dir-use-symlinks False
            # Rename to expected path
            DOWNLOADED="$(dirname "${MODEL_PATH}")/${MODEL_HF_FILE}"
            if [ "${DOWNLOADED}" != "${MODEL_PATH}" ] && [ -f "${DOWNLOADED}" ]; then
                mv "${DOWNLOADED}" "${MODEL_PATH}"
            fi
        else
            HF_URL="https://huggingface.co/${MODEL_HF_REPO}/resolve/main/${MODEL_HF_FILE}"
            echo "[startup]   URL: ${HF_URL}"
            curl -L -o "${MODEL_PATH}" "${HF_URL}"
        fi
        echo "[startup] Download complete: $(ls -lh "${MODEL_PATH}" | awk '{print $5}')"
    else
        echo "[startup] ERROR: MODEL_HF_REPO set but MODEL_HF_FILE not specified."
        exit 1
    fi
fi

# --- Verify model exists ---
if [ ! -f "${MODEL_PATH}" ]; then
    echo "[startup] ERROR: Model not found at ${MODEL_PATH}"
    echo "[startup] Set MODEL_PATH to point to your GGUF file,"
    echo "[startup] or set MODEL_HF_REPO + MODEL_HF_FILE to download one."
    exit 1
fi

# --- Start the health-check proxy in the background ---
echo "[startup] Starting health-check proxy on port ${HEALTH_PORT}..."
export LLAMA_SERVER_PORT="${MAIN_PORT}"
python3 -u /app/health_proxy.py &
HEALTH_PID=$!

# --- Build llama-server arguments ---
LLAMA_ARGS=(
    --model "${MODEL_PATH}"
    --host "0.0.0.0"
    --port "${MAIN_PORT}"
    --n-gpu-layers "${N_GPU_LAYERS}"
    --ctx-size "${CTX_SIZE}"
    --parallel "${N_PARALLEL}"
    --cont-batching
    --flash-attn
    --metrics
)

# Add any extra arguments
if [ -n "${LLAMA_EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2206
    LLAMA_ARGS+=(${LLAMA_EXTRA_ARGS})
fi

# --- Launch llama-server (foreground — becomes PID 1 effectively) ---
echo "[startup] Starting llama-server on port ${MAIN_PORT}..."
echo "[startup] Full command: llama-server ${LLAMA_ARGS[*]}"
exec llama-server "${LLAMA_ARGS[@]}"
```

**Notes:**

- `exec` replaces the shell process with llama-server, so it becomes PID 1 and receives signals properly (important for graceful shutdown).
- The health proxy starts first in the background. It immediately returns 204 while llama-server is loading, which keeps RunPod from terminating the worker during model load.
- `--cont-batching` enables continuous batching for better throughput with concurrent requests.
- `--flash-attn` enables flash attention for faster inference (supported on most CUDA GPUs).
- The HuggingFace download logic handles the case where you don't bake the model into the image (see Section 8).

---

## 7. Dockerfile

This Dockerfile builds llama.cpp from source with CUDA support and bundles the health proxy.

### `Dockerfile`

```dockerfile
# =============================================================================
# RunPod Serverless Load Balancer Worker — llama.cpp
# =============================================================================
# Multi-stage build:
#   Stage 1: Build llama.cpp from source with CUDA
#   Stage 2: Minimal runtime image
# =============================================================================

# --- Stage 1: Build llama.cpp ---
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone and build llama.cpp
ARG LLAMA_CPP_VERSION=master
RUN git clone --depth 1 --branch ${LLAMA_CPP_VERSION} \
    https://github.com/ggml-org/llama.cpp.git /build/llama.cpp

WORKDIR /build/llama.cpp

RUN cmake -B build \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_CUDA=ON \
    -DLLAMA_CURL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -j$(nproc) --target llama-server

# --- Stage 2: Runtime image ---
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    libcurl4 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for health proxy
RUN pip3 install --no-cache-dir --break-system-packages \
    fastapi==0.115.* \
    uvicorn==0.34.* \
    httpx==0.28.*

# Copy llama-server binary from builder
COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

# Copy application files
COPY health_proxy.py /app/health_proxy.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Create model directory
RUN mkdir -p /models

# --- Default environment variables ---
ENV PORT=8080
ENV PORT_HEALTH=3000
ENV MODEL_PATH=/models/model.gguf
ENV N_GPU_LAYERS=-1
ENV CTX_SIZE=8192
ENV N_PARALLEL=4

# Expose ports
EXPOSE 8080 3000

# Start
CMD ["/app/start.sh"]
```

**Build notes:**

- **Multi-stage build** keeps the final image small — the devel image (with compilers, headers) is only used for compilation.
- `DGGML_CUDA=ON` enables GPU acceleration. This requires the NVIDIA CUDA toolkit in the build stage.
- `DLLAMA_CURL=ON` enables built-in model downloading from URLs (useful if you want `--model-url` support).
- The runtime image uses `cuda:12.4.1-runtime` which includes the CUDA runtime libraries but not the full toolkit.
- You can pin a specific llama.cpp release by changing `LLAMA_CPP_VERSION` (e.g., `b5200`).

---

## 8. Model Delivery Strategy

You have three options for getting the GGUF model into your worker. Choose based on your priorities:

### Option A: Bake the Model into the Docker Image

Best for: small to medium models (≤ 10 GB), fastest cold start, simplest setup.

Add this to your Dockerfile before the `CMD` line:

```dockerfile
# Download model during image build
ARG MODEL_URL="https://huggingface.co/bartowski/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf"
RUN curl -L -o /models/model.gguf "${MODEL_URL}"
```

**Pros:** Zero cold-start download time. Workers are ready as soon as the container starts and the model loads into GPU memory.

**Cons:** Docker image becomes very large. Pushing/pulling is slow. Changing models requires rebuilding the image.

### Option B: RunPod Network Volume

Best for: large models, shared across multiple endpoints, persistent storage.

1. Create a Network Volume in the RunPod console (Storage → Network Volumes).
2. Upload your GGUF file to the volume (via a temporary pod or the RunPod CLI).
3. When creating your endpoint, attach the network volume.
4. Set `MODEL_PATH` to point to the file on the volume (e.g., `/runpod-volume/models/my-model.gguf`).

**Pros:** Model persists across worker restarts. Shared across endpoints. No image bloat.

**Cons:** Network volume is region-specific. Slight I/O overhead reading from network storage. Volume incurs a small hourly storage cost.

### Option C: Download at Startup from HuggingFace

Best for: flexibility, experimenting with different models without rebuilding images.

Set these environment variables on your endpoint:

```
MODEL_HF_REPO=bartowski/Qwen3-8B-GGUF
MODEL_HF_FILE=Qwen3-8B-Q4_K_M.gguf
MODEL_PATH=/models/model.gguf
```

The `start.sh` script will download the model on first boot. Subsequent boots (with FlashBoot or if the container is cached) may skip the download.

**Pros:** Swap models by changing env vars. No image rebuild needed.

**Cons:** Adds significant cold-start time (downloading a multi-GB file). Not ideal for production with scale-to-zero.

### Recommendation

For production with models you've settled on: **Option B (Network Volume)** is the best balance. For development/testing: **Option C (HuggingFace download)** is most flexible. For small models in production: **Option A (baked in)** gives the fastest cold starts.

---

## 9. Building and Pushing the Docker Image

```bash
# Clone or create your project directory
mkdir runpod-llamacpp-lb && cd runpod-llamacpp-lb

# ... create Dockerfile, health_proxy.py, start.sh as shown above ...

# Build the image (must target linux/amd64 for RunPod)
docker build --platform linux/amd64 \
    -t YOUR_DOCKERHUB_USER/llamacpp-runpod-lb:latest .

# (Optional) Build with a specific llama.cpp version
docker build --platform linux/amd64 \
    --build-arg LLAMA_CPP_VERSION=b5200 \
    -t YOUR_DOCKERHUB_USER/llamacpp-runpod-lb:b5200 .

# Push to Docker Hub
docker push YOUR_DOCKERHUB_USER/llamacpp-runpod-lb:latest
```

**Important:** The `--platform linux/amd64` flag is required. RunPod workers only run on amd64 architecture. If you're building on an Apple Silicon Mac or ARM system, this ensures cross-compilation.

Build time will be significant (10–30 minutes) because llama.cpp compiles from source with CUDA. Subsequent builds will be faster due to Docker layer caching.

---

## 10. Deploying to RunPod

### Step-by-Step Console Deployment

1. Go to **[console.runpod.io/serverless](https://console.runpod.io/serverless)**.
2. Click **New Endpoint**.
3. Click **Import from Docker Registry**.
4. Enter your container image: `YOUR_DOCKERHUB_USER/llamacpp-runpod-lb:latest`
5. Click **Next**.
6. Configure the endpoint:
   - **Endpoint Name:** Something descriptive (e.g., `llamacpp-qwen3-8b`)
   - **Endpoint Type:** Select **Load Balancer** ← critical!
   - **GPU Configuration:** Choose based on your model size:
     - 7–8B Q4: 16 GB GPU (RTX 4000 Ada, A4000)
     - 8B Q8 / 13B Q4: 24 GB GPU (RTX 4090, A5000, L4)
     - 27–30B Q4: 48 GB GPU (A6000, L40, RTX 6000 Ada)
     - 70B Q4: 80 GB GPU (A100, H100)
   - **Active Workers:** 0 (for cost savings) or 1+ (for zero cold-start)
   - **Max Workers:** Start with 1 for testing, increase for production
   - **Idle Timeout:** 5–30 seconds depending on traffic pattern
   - **FlashBoot:** Enable (reduces cold start times significantly)
7. Under **Expose HTTP Ports**, add: `8080, 3000`
8. Under **Environment Variables**, add:

   | Variable | Value | Notes |
   |---|---|---|
   | `PORT` | `8080` | Main llama-server port |
   | `PORT_HEALTH` | `3000` | Health proxy port |
   | `MODEL_PATH` | `/models/model.gguf` | Adjust for your model location |
   | `N_GPU_LAYERS` | `-1` | -1 = offload all layers to GPU |
   | `CTX_SIZE` | `8192` | Adjust to your model's capability |
   | `N_PARALLEL` | `4` | Concurrent inference slots |

   If using HuggingFace download (Option C), also add:
   | Variable | Value |
   |---|---|
   | `MODEL_HF_REPO` | `bartowski/Qwen3-8B-GGUF` |
   | `MODEL_HF_FILE` | `Qwen3-8B-Q4_K_M.gguf` |

9. If using a Network Volume (Option B), attach it under **Network Volume**.
10. Click **Deploy Endpoint**.

### Your Endpoint URL

After deployment, your endpoint ID will be visible on the Serverless dashboard. Your base URL is:

```
https://<ENDPOINT_ID>.api.runpod.ai
```

All llama-server paths are accessible directly under this URL.

---

## 11. Testing Your Endpoint

### Health Check

```bash
export RUNPOD_API_KEY="your_api_key_here"
export ENDPOINT_ID="your_endpoint_id"
export BASE_URL="https://${ENDPOINT_ID}.api.runpod.ai"

# Ping the health endpoint
curl -s "${BASE_URL}/ping" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}"
```

Expected response when ready: `{"status": "healthy"}`

### OpenAI-Compatible Chat Completions

```bash
curl -s "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "any-string-here",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Explain quantum computing in one paragraph."}
        ],
        "max_tokens": 256,
        "temperature": 0.7
    }'
```

**Note:** llama-server serves a single model, so the `model` field is effectively ignored — you can pass any string.

### Streaming Chat Completions

```bash
curl -s -N "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "my-model",
        "messages": [
            {"role": "user", "content": "Write a haiku about cloud computing."}
        ],
        "stream": true,
        "max_tokens": 100
    }'
```

### Completions (Non-Chat)

```bash
curl -s "${BASE_URL}/v1/completions" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "my-model",
        "prompt": "The three laws of robotics are:",
        "max_tokens": 200
    }'
```

### Embeddings

```bash
curl -s "${BASE_URL}/v1/embeddings" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "my-model",
        "input": "This is a test sentence for embeddings."
    }'
```

### Using the OpenAI Python SDK

```python
from openai import OpenAI
import os

client = OpenAI(
    base_url=f"https://{os.environ['ENDPOINT_ID']}.api.runpod.ai/v1",
    api_key=os.environ["RUNPOD_API_KEY"],
)

response = client.chat.completions.create(
    model="any-model-name",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is the meaning of life?"},
    ],
    max_tokens=256,
    temperature=0.7,
)

print(response.choices[0].message.content)
```

### Retry Wrapper for Cold Starts

When workers scale from zero, the first request may fail with "no workers available." Use retry logic:

```python
import time
import requests

def query_with_retry(base_url, api_key, payload, max_retries=5, delay=10):
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    for attempt in range(max_retries):
        try:
            resp = requests.post(
                f"{base_url}/v1/chat/completions",
                headers=headers,
                json=payload,
                timeout=120,
            )
            if resp.status_code == 200:
                return resp.json()
            elif "no workers available" in resp.text.lower():
                print(f"[attempt {attempt+1}] Workers spinning up, retrying in {delay}s...")
                time.sleep(delay)
            else:
                resp.raise_for_status()
        except requests.exceptions.Timeout:
            print(f"[attempt {attempt+1}] Timeout, retrying in {delay}s...")
            time.sleep(delay)

    raise RuntimeError("Failed after max retries — workers never became available")
```

---

## 12. Tuning llama.cpp Server Parameters

These can be set via the `LLAMA_EXTRA_ARGS` environment variable or by modifying `start.sh`.

### Key Parameters

| Parameter | Env Var | Default | Notes |
|---|---|---|---|
| `--n-gpu-layers` | `N_GPU_LAYERS` | `-1` | -1 offloads all layers. Set lower if VRAM is tight. |
| `--ctx-size` | `CTX_SIZE` | `8192` | Total context window in tokens. Larger = more VRAM. |
| `--parallel` | `N_PARALLEL` | `4` | Concurrent request slots. Each slot reserves ctx_size/parallel tokens. |
| `--cont-batching` | — | enabled | Continuous batching — essential for throughput. |
| `--flash-attn` | — | enabled | Flash attention — faster, less memory. Requires supported GPU. |
| `--threads` | — | auto | CPU threads. Usually auto-detected is fine. |
| `--cache-type-k` | — | `f16` | KV cache precision for keys. Options: f16, q8_0, q4_0. Lower = less VRAM but slight quality loss. |
| `--cache-type-v` | — | `f16` | KV cache precision for values. Same tradeoffs. |
| `--metrics` | — | enabled | Enables the `/metrics` Prometheus endpoint for monitoring. |

### VRAM Estimation

A rough formula for VRAM usage:

```
VRAM ≈ model_size + (ctx_size × n_parallel × kv_cache_bytes_per_token)
```

For a Q4_K_M quantized model:
- 8B model ≈ 5 GB base
- Each 4096-token context slot ≈ 0.5 GB (with f16 KV cache)
- So 4 parallel slots with 8192 ctx: ~5 + (4 × 1.0) ≈ 9 GB → fits in 16 GB GPU

For a 70B Q4_K_M:
- Base model ≈ 40 GB
- 4 slots × 8192 ctx ≈ 8 GB
- Total ≈ 48 GB → needs 80 GB GPU (or reduce parallel/ctx_size for 48 GB)

### Example: High-Throughput Configuration

```bash
LLAMA_EXTRA_ARGS="--cache-type-k q8_0 --cache-type-v q8_0 --threads 8"
N_PARALLEL=8
CTX_SIZE=4096
```

### Example: Maximum Context Configuration

```bash
N_PARALLEL=1
CTX_SIZE=131072
LLAMA_EXTRA_ARGS="--cache-type-k q4_0 --cache-type-v q4_0 --rope-scaling yarn"
```

---

## 13. Scaling and Cost Strategy

### Worker Types

- **Active Workers:** Always running, no cold start. Billed at a 40% discount from flex rate, but you pay even when idle. Use for your baseline expected load.
- **Flex Workers (Max Workers):** Scale up on demand, scale to zero when idle. Cold start penalty, but you only pay during active inference. Use for burst capacity.

### Strategy Recommendations

| Scenario | Active Workers | Max Workers | Idle Timeout |
|---|---|---|---|
| Development/testing | 0 | 1 | 5 seconds |
| Low-traffic production | 1 | 3 | 30 seconds |
| High-traffic production | 2–3 | 10 | 60 seconds |
| Batch processing (not typical for LB) | 0 | 5 | 5 seconds |

### Cost Optimization Tips

1. **Enable FlashBoot.** It dramatically reduces cold start times by caching container state.
2. **Use quantized KV cache** (`--cache-type-k q8_0 --cache-type-v q8_0`) to fit more parallel slots in the same VRAM, improving throughput per dollar.
3. **Right-size your GPU.** Don't use an A100 for a 7B model — an RTX 4090 or L4 will be faster and cheaper.
4. **Use Network Volumes** to avoid re-downloading models on cold start.
5. **Tune idle timeout.** Too short = frequent cold starts. Too long = paying for idle time.
6. **Monitor with `/metrics`.** The Prometheus endpoint gives you tokens/second, queue depth, and slot utilization.

---

## 14. Troubleshooting

### "no workers available"

This means no worker was ready within RunPod's 2-minute timeout. Common causes:
- Model download taking too long at startup (use Network Volume or baked-in model)
- Model too large for the selected GPU (OOM during load)
- Workers haven't spun up yet — implement client-side retry logic

### "not allowed for QB API"

You're trying to use queue-based API paths (`/run`, `/runsync`) on a load-balancer endpoint, or vice versa. Verify your endpoint type is set to **Load Balancer** in the RunPod console.

### 502 errors

Workers are up but ports are misconfigured. Verify:
- `PORT` environment variable matches what llama-server is listening on (default 8080)
- `PORT_HEALTH` is set to a different port than `PORT` (default 3000)
- Both ports are listed under "Expose HTTP Ports" in endpoint config

### Workers stuck in "initializing"

The health proxy is returning 204 indefinitely. Check worker logs for:
- Model file not found (`MODEL_PATH` is wrong)
- CUDA errors (GPU incompatibility)
- Out of memory (model too large for GPU)

### Slow responses / timeouts

- RunPod has a 5.5-minute per-request processing timeout
- Reduce `max_tokens` in your request
- Reduce `N_PARALLEL` to give each slot more GPU bandwidth
- Use a faster quantization (Q4_K_M is a good balance)

### Model loads but /v1/chat/completions returns errors

- Ensure the model supports chat (has a chat template). Some base models don't.
- Add `--jinja` to `LLAMA_EXTRA_ARGS` if the model uses a Jinja2 chat template.
- Check that the model is GGUF format (not GGML, safetensors, or other).

---

## 15. Complete File Listing

For easy copy-paste, here is every file in the project:

### `Dockerfile`

*(See Section 7 above)*

### `health_proxy.py`

*(See Section 5 above)*

### `start.sh`

*(See Section 6 above)*

### `.dockerignore`

```
.git
.env
*.md
__pycache__
```

---

## Quick-Start Cheat Sheet

```bash
# 1. Create project
mkdir runpod-llamacpp-lb && cd runpod-llamacpp-lb

# 2. Create files (Dockerfile, health_proxy.py, start.sh, .dockerignore)
#    ... paste contents from sections 5, 6, 7 above ...

# 3. Build
docker build --platform linux/amd64 -t myuser/llamacpp-lb:latest .

# 4. Push
docker push myuser/llamacpp-lb:latest

# 5. Deploy on RunPod
#    Console → Serverless → New Endpoint → Docker Registry
#    Image: myuser/llamacpp-lb:latest
#    Endpoint Type: Load Balancer
#    Expose HTTP Ports: 8080, 3000
#    Environment Variables:
#      PORT=8080
#      PORT_HEALTH=3000
#      MODEL_HF_REPO=bartowski/Qwen3-8B-GGUF
#      MODEL_HF_FILE=Qwen3-8B-Q4_K_M.gguf
#    GPU: 16 GB or 24 GB
#    Deploy!

# 6. Test
curl -s "https://ENDPOINT_ID.api.runpod.ai/v1/chat/completions" \
    -H "Authorization: Bearer YOUR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"test","messages":[{"role":"user","content":"Hello!"}]}'
```

---

*Guide last updated: March 2026. Based on RunPod load balancing docs and llama.cpp server as of early 2026.*
