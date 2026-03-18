<p align="center">
    <img src="https://raw.githubusercontent.com/ggml-org/llama.cpp/master/media/llama1-icon-transparent.png" alt="llama.cpp logo" width="128">
</p>

# RunPod llama.cpp inference load-balancer worker

This repository contains a serverless inference worker (load balancer only, it does not work for queued).  It uses llama.cpp to serve inference. It uses the `ghcr.io/ggml-org/llama.cpp:server-cuda` image as a base, with a `start.sh` bash script and `proxy.js` to respond to `/ping` requests, ensuring the serverless machinery knows when llama-server is healthy.

This project is based on [Jacob-ML/inference-worker](https://github.com/Jacob-ML/inference-worker/), which was a fork of [SvenBrnn's `runpod-worker-ollama`](https://github.com/SvenBrnn/runpod-worker-ollama).

## Setup

To get the best performance out of this worker, it is recommended to use cached models. Please see the [cached models documentation](./docs/cached.md) for more information, this is **highly recommended and will save many resources**.

Cached modules documentation isn't great.  As of March 15th 2026, this is how it works:

1. Specify model in the serverless dialogue.
2. On worker start, it first downloads docker image.
3. Then it populates `/runpod-volumes/huggingface-cache/hub/model--unsloth--qwen3.5-27b-gguf/xxxxx` where the model name is `unsloth/Qwen3.5-27B-GGUF:UD-Q4_K_XL` and `xxxxx` are all the quants for this model.

During setup/dev phase, it's often faster to use `LLAMA_ARG_HF_REPO` and set the `LLAMA_CACHE` to the network volume path (e.g. `/runpod-volumes`).  Then llama.cpp will download what it needs the first time.  However this configuration can only be used with a single datacenter - because the network storage volume must be in the same datacenter as the serverless workers.

In production, runpod model cache system is more flexible.  Workers start more slowly, because the model cache takes a while to download (particularly for 20+ GB models) on each worker.  But once all the workers have initialized - they are quick - particularly with flashboot.

## Configuration

Configure `proxy.js` via environment variables:

| Variable | Description |
|---|---|
| `HEALTH_PORT` | Port that will respond to http get /ping. (default: `3000`) |

Also configure `llama-server` via environment variables:

| Variable | Description |
|---|---|
| `LLAMA_ARG_HF_REPO` | Hugging Face repository to download the model from (e.g., `unsloth/Qwen3.5-27B-GGUF:UD-Q4_K_XL`) |
| `LLAMA_ARG_N_GPU_LAYERS` | Number of model layers to offload to the GPU (`-1` for all layers) |
| `LLAMA_ARG_CTX_SIZE` | Context size (number of tokens the model can process at once) |
| `LLAMA_ARG_N_PARALLEL` | Number of parallel sequences to decode (enables concurrent request handling) |
| `LLAMA_ARG_HOST` | Host address for the server to listen on (default: `127.0.0.1`) |
| `LLAMA_ARG_PORT` | Port for the server to listen on (default: `8080`) |
| `LLAMA_API_KEY` | API key required for client authentication to the server |
| `LLAMA_CACHE` | Directory path for storing downloaded and cached model files |

## License

Please see the [LICENSE](./LICENSE) file for more information.
