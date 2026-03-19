<p align="center">
    <img src="https://raw.githubusercontent.com/ggml-org/llama.cpp/master/media/llama1-icon-transparent.png" alt="llama.cpp logo" width="128">
</p>

# RunPod llama.cpp inference worker

This repository contains a serverless inference worker for RunPod.  Supports both load balancer and queue modes.  It uses llama.cpp `llama-server`, via the docker image `ghcr.io/ggml-org/llama.cpp:server-cuda`.   This repo builds in a `start.sh` bash script and `proxy.js` to handle `/ping` health checks and queue job processing.

This project is based on [Jacob-ML/inference-worker](https://github.com/Jacob-ML/inference-worker/), which was a fork of [SvenBrnn's `runpod-worker-ollama`](https://github.com/SvenBrnn/runpod-worker-ollama).

## Setup

To get the best performance out of this worker, it is recommended to use cached models. Please see the [cached models documentation](./docs/cached.md) for more information, this is **highly recommended and will save many resources**.

Cached modules documentation isn't great.  As of March 15th 2026, this is how it works:

1. Specify model in the serverless dialogue.
2. On worker start, it first downloads docker image.
3. Then it populates `/runpod-volumes/huggingface-cache/hub/model--unsloth--qwen3.5-27b-gguf/xxxxx` where the model name is `unsloth/Qwen3.5-27B-GGUF:UD-Q4_K_XL` and `xxxxx` are all the quants for this model.

During setup/dev phase, it's often faster to use `LLAMA_ARG_HF_REPO` and set the `LLAMA_CACHE` to the network volume path (e.g. `/runpod-volume`).  Then llama.cpp will download what it needs the first time.  However this configuration can only be used with a single datacenter - because the network storage volume must be in the same datacenter as the serverless worker.

In production, runpod model cache system is more flexible.  Workers start more slowly, because the model cache takes a while to populate (particularly for 20+ GB models), for the worker.  Once the worker has initialized, particularly with flashboot, its very very quick.

## Configuration

Runpod Serverless

| Env Variable | Description |
|---|---|
| `PORT` | Port that will respond to regular http requests (default: `8080`) |
| `PORT_HEALTH` | Port that will respond to http get /ping. (default: `3000`) |

`proxy.js`

| Env Variable | Description |
|---|---|
| `LLAMA_SERVER_HOST` | llama-server http address (default: `127.0.0.1`) |
| `LLAMA_ARG_PORT` | llama-server http port (default: `8080`) |
| `PORT_HEALTH` | Port that will respond to http get /ping. (default: `3000`) |
| `SERVERLESS_MODE` | `queue`, `lb`, or unset for auto-detect. See below. |
| `QUEUE_TIMEOUT` | Timeout in ms for queue job requests (default: `300000`) |

### Serverless modes

Set `SERVERLESS_MODE` to control how the proxy handles requests:

- **`lb`** — Load balancer mode. All non-`/ping` requests are proxied directly to llama-server. Use this when RunPod sends raw HTTP requests (e.g. OpenAI-compatible calls) to the worker.
- **`queue`** — Queue mode. All non-`/ping` requests must be RunPod queue job payloads (`{"id": "...", "input": {...}}`). The proxy extracts the `input`, forwards it to llama-server, and wraps the response in `{"output": ...}`. For queue mode, set RunPod's `PORT` to the proxy port (default `3000`).
- **Unset** — Auto-detect per request. If the POST body contains an `input` object, it is treated as a queue job; otherwise it is proxied directly.

### Queue input format

```json
{
  "id": "job-123",
  "input": {
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }
}
```

Reserved keys in `input` (extracted before forwarding to llama-server):

| Key | Description |
|---|---|
| `endpoint` | llama-server path (default: auto-detected from body content) |
| `method` | HTTP method (default: `POST`) |

Auto-detection: if `messages` is present → `/v1/chat/completions`; if `prompt` is present → `/v1/completions`; otherwise `/v1/chat/completions`.

Streaming is supported — set `"stream": true` in the input and the SSE stream from llama-server is passed through directly.

`llama-server`

| Env Variable | Description |
|---|---|
| `LLAMA_ARG_HF_REPO` | Hugging Face repository to download the model from (e.g., `unsloth/Qwen3.5-27B-GGUF:UD-Q4_K_XL`) |
| `LLAMA_ARG_N_GPU_LAYERS` | Number of model layers to offload to the GPU (`-1` for all layers) |
| `LLAMA_ARG_CTX_SIZE` | Context size (number of tokens the model can process at once) |
| `LLAMA_ARG_N_PARALLEL` | Number of parallel sequences to decode (enables concurrent request handling) |
| `LLAMA_ARG_HOST` | Host address for the server to listen on (default: `127.0.0.1`) |
| `LLAMA_ARG_PORT` | Port for the server to listen on (default: `8080`) |
| `LLAMA_API_KEY` | API key required for client authentication to the server |
| `LLAMA_CACHE` | Directory downloaded/cached model files (`/runpod-volume` when using network volumes) |

More: [README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

## License

Please see the [LICENSE](./LICENSE) file for more information.
