#!/bin/bash

# fail on error:
set -e -o pipefail

# This script starts the llama-server with the command line arguments
# specified in the environment variable LLAMA_SERVER_CMD_ARGS, ensuring
# that the server listens on port 3098. It also starts the handler.py
# script after the server is up and running.

cleanup() {
    echo "******** Cleaning up..."
    pkill -P $$ # kill all child processes of the current script
    exit 0
}

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

# check if $LLAMA_SERVER_CMD_ARGS is set
if [ -z "$LLAMA_SERVER_CMD_ARGS" ]; then
    echo "******** Warning: LLAMA_SERVER_CMD_ARGS is not set. Defaulting to -hf unsloth/gemma-3-270m-it-GGUF:IQ2_XXS --ctx-size 512 -ngl 999"
    LLAMA_SERVER_CMD_ARGS="-hf unsloth/gemma-3-270m-it-GGUF:IQ2_XXS --ctx-size 512 -ngl 999"
fi

# check if the substring --port is in LLAMA_SERVER_CMD_ARGS and if yes, raise an error:
if [[ "$LLAMA_SERVER_CMD_ARGS" == *"--port"* ]]; then
    echo "******** Error: You must not define --port in LLAMA_SERVER_CMD_ARGS, as port 3098 is required."
    exit 1
fi

# trap exit signals and call the cleanup function
trap cleanup SIGINT SIGTERM

# kill any existing llama-server processes
echo "******** Stopping existing llama-server instances (if any)..."
{
    pkill llama-server 2>/dev/null
} || {
    echo "******** No llama-server running"
}

# we have a string with all the command line arguments in the env var LLAMA_SERVER_CMD_ARGS;
# it contains a.e. "-hf modelname --ctx-size 4096 -ngl 999".

echo "******** Running /app/llama-server $CACHED_LLAMA_ARGS $LLAMA_SERVER_CMD_ARGS --port 3098"

touch llama.server.log

# --- Start the health-check proxy in the background ---
echo "[startup] Starting health-check proxy on port ${HEALTH_PORT}..."
export LLAMA_SERVER_PORT="${MAIN_PORT}"
python3 -u /health_proxy.py &
HEALTH_PID=$!

# We need to pass these arguments to llama-server verbatim.
cd /app
exec ./llama-server $CACHED_LLAMA_ARGS $LLAMA_SERVER_CMD_ARGS --port 3098 2>&1 | tee llama.server.log &
# LLAMA_SERVER_PID=$! # store the process ID (PID) of the background command

