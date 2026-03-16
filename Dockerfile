# Use an official ggml-org/llama.cpp image as the base image
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

# Set up the working directory
WORKDIR /app

RUN apt-get update --yes --quiet \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet --no-install-recommends \
       nodejs bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 proxy.js start.sh /app

ENTRYPOINT ["/bin/bash", "-c", "/app/start.sh"]
