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
echo "--- find /runpod-volume -printf '%s %p' | head -n 50 ---"
find /runpod-volume -printf '%s %p\n' | head -n 50
echo "================================================"

# - Starts llama-server with cached model file, if found.
# - proxy.js, for serverless health /ping.

LLAMA_ARGS=""

# If LLAMA_ARG_HF_REPO is set, attempt to resolve a cached GGUF from the HF cache
if [ -n "$LLAMA_ARG_HF_REPO" ]; then
    HF_CACHE_DIR="/runpod-volume/huggingface-cache/hub"
    if [ -d "$HF_CACHE_DIR" ]; then
        echo "******** LLAMA_ARG_HF_REPO is set to: $LLAMA_ARG_HF_REPO"
        echo "******** Searching HF cache at $HF_CACHE_DIR for cached model..."

        # Convert repo name to HF cache directory format (org/repo -> models--org--repo)
        cache_name=$(echo "$LLAMA_ARG_HF_REPO" | sed 's|/|--|g')
        snapshots_dir="${HF_CACHE_DIR}/models--${cache_name}/snapshots"

        if [ -d "$snapshots_dir" ]; then
            snapshot=$(ls "$snapshots_dir" | head -n 1)
            if [ -n "$snapshot" ]; then
                snapshot_path="${snapshots_dir}/${snapshot}"
                echo "--- ls -aFl $snapshot_path | head -n 50 ---"
                ls -aFl "$snapshot_path" | head -n 50

                # Look for the exact file specified by LLAMA_ARG_HF_FILE
                if [ -n "$LLAMA_ARG_HF_FILE" ] && [ -f "${snapshot_path}/${LLAMA_ARG_HF_FILE}" ]; then
                    export LLAMA_ARG_HF_FILE="${snapshot_path}/${LLAMA_ARG_HF_FILE}"
                    echo "******** Found cached model file: $LLAMA_ARG_HF_FILE"
                else
                    echo "******** No cached file matching LLAMA_ARG_HF_FILE='${LLAMA_ARG_HF_FILE}' in $snapshot_path"
                fi
            else
                echo "******** No snapshots found in $snapshots_dir"
            fi
        else
            echo "******** Cache directory not found: $snapshots_dir"
        fi
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
