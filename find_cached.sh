#!/bin/bash

# Finds the full LLM GGUF path from the Hugging Face cache.

CACHE_DIR="/runpod-volume/huggingface-cache/hub"

model="$1"
gguf_in_repo="${2:-model.gguf}"

cache_name=$(echo "${model}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
snapshots_dir="${CACHE_DIR}/models--${cache_name}/snapshots"

if [ -d "${snapshots_dir}" ]; then
    snapshot=$(ls "${snapshots_dir}" | head -n 1)
    if [ -n "${snapshot}" ]; then
        printf '%s' "${snapshots_dir}/${snapshot}/${gguf_in_repo}"
        exit 0
    fi
fi

printf ''
