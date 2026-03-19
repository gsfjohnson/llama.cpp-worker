#!/bin/bash

# fail on error:
set -e -o pipefail

echo "================================================"
echo "  RunPod llama.cpp Worker (type: load balancer)"
echo "================================================"
env | grep -E '^LLAMA_|^RUNPOD_|^RP_' | sort || echo "No matching environment variables found."
echo "================================================"
echo "nodejs $(node -v)"
echo "================================================"
echo "--- find /runpod-volume -type f -iname '*.gguf' -printf '%p %s' | head -n 50 ---"
find /runpod-volume -type f -iname '*.gguf' -printf '%p %s\n' | head -n 50
echo "================================================"

# - Starts llama-server with cached model file, if found.
# - proxy.js, for serverless health /ping.

LLAMA_ARGS=""

# If LLAMA_ARG_HF_REPO is set and LLAMA_ARG_HF_FILE is not, search the cache for a matching model
HF_CACHE_DIR="/runpod-volume/huggingface-cache/hub"
if [ -d "$HF_CACHE_DIR" ] && [ -n "$LLAMA_ARG_HF_REPO" ] && [ -z "$LLAMA_ARG_HF_FILE" ]; then
    # If repo contains ":", split into repo and quant (e.g. "org/repo:Q4_K_M")
    hf_repo="$LLAMA_ARG_HF_REPO"
    if [[ "$hf_repo" == *":"* ]]; then
        quant="${LLAMA_ARG_HF_REPO##*:}"
        hf_repo="${LLAMA_ARG_HF_REPO%%:*}"
        echo "******** Repo: $hf_repo"
        echo "******** Quant: $quant"
    else
        echo "******** Repo: $hf_repo"
        quant=""
    fi

    # Convert repo name to HF cache directory format (org/repo -> models--org--repo)
    cache_name=$(echo "$hf_repo" | tr '[:upper:]' '[:lower:]' | sed 's|/|--|g')
    snapshot_dir="${HF_CACHE_DIR}/models--${cache_name}/snapshots"

    echo "******** Searching $snapshot_dir ..."

    if [ -n "$quant" ]; then
        cached_file=$(find "$snapshot_dir" -type f -iname "*${quant}.gguf" | head -n 1)
    else
        cached_file=$(find "$snapshot_dir" -type f -iname "*.gguf" | grep -v mmproj | head -n 1)
    fi
    if [ -n "$cached_file" ]; then
        export LLAMA_ARGS="-m $cached_file"
        unset LLAMA_ARG_HF_REPO
        echo "******** unset LLAMA_ARG_HF_REPO"
        echo "******** LLAMA_ARGS: $LLAMA_ARGS"
    fi
fi

# trap exit signals and call the cleanup function
#trap cleanup SIGINT SIGTERM

# kill any existing llama-server processes
echo "******** Stopping existing llama-server instances (if any)..."
{
    pkill llama-server 2>/dev/null
} || {
    echo "******** No llama-server running"
}

touch llama.server.log

# --- Start the health-check proxy in the background ---
export HEALTH_PORT="${HEALTH_PORT:-3000}"
echo "******** Starting health-check proxy on port ${HEALTH_PORT}..."
node /app/proxy.js &
HEALTH_PID=$!

# We need to pass these arguments to llama-server verbatim.
cd /app
echo "******** exec /app/llama-server $LLAMA_ARGS"
exec /app/llama-server $LLAMA_ARGS 2>&1 | tee llama.server.log
# LLAMA_SERVER_PID=$! # store the process ID (PID) of the background command
