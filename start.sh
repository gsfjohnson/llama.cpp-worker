#!/bin/bash

# fail on error:
set -e -o pipefail

echo "================================================"
echo "  RunPod llama.cpp Worker (type: load balancer)"
echo "================================================"
env | grep '^LLAMA_' | sort || true
echo "================================================"

# - Starts llama-server with cached model file, if found.
# - health_proxy.py, for serverless health /ping.

CACHED_LLAMA_ARGS=""

find_cached_path() {
    local cache_dir="/runpod-volume/huggingface-cache/hub"
    local model="$LLAMA_CACHED_MODEL"
    local gguf_in_repo="${LLAMA_CACHED_GGUF_PATH:-model.gguf}"

    ls $cache_dir | head -n 50

    local cache_name
    cache_name=$(echo "${model}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
    local snapshots_dir="${cache_dir}/models--${cache_name}/snapshots"

    if [ -d "${snapshots_dir}" ]; then
        local snapshot
        snapshot=$(ls "${snapshots_dir}" | head -n 1)
        if [ -n "${snapshot}" ]; then
            CACHED_LLAMA_ARGS="-m ${snapshots_dir}/${snapshot}/${gguf_in_repo}"
            return
        fi
    fi

    echo "******** Warning: Could not find cached model path for ${model}"
    CACHED_LLAMA_ARGS=""
}

# check if $LLAMA_CACHED_MODEL is set and not empty
if [ -n "$LLAMA_CACHED_MODEL" ]; then
    echo "******** Caching is enabled. Finding cached model path..."
    find_cached_path

    echo "******** Using cached model with arguments: $CACHED_LLAMA_ARGS"
else
    echo "******** WARNING: Caching is disabled. Please visit the inference-worker README and docs to learn more."
fi

if [ ! -z "$LLAMA_SERVER_ONLY_HEALTH" ]; then
    echo "******** Exec: python3 -u /health_proxy.py"
    exec python -u /app/health_proxy.py
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
python -u /app/health_proxy.py &
HEALTH_PID=$!

# We need to pass these arguments to llama-server verbatim.
cd /app
echo "******** /app/llama-server $CACHED_LLAMA_ARGS"
if [ "$LLAMA_EXEC" != "0" ]; then
  echo "******** exec"
  exec /app/llama-server $CACHED_LLAMA_ARGS 2>&1 | tee llama.server.log
else
  echo "******** not exec"
  /app/llama-server $CACHED_LLAMA_ARGS 2>&1 | tee llama.server.log
fi
# LLAMA_SERVER_PID=$! # store the process ID (PID) of the background command
