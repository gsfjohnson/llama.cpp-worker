# Use an official ggml-org/llama.cpp image as the base image
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

ENV PYTHONUNBUFFERED=1

# Set up the working directory
WORKDIR /

# Startup Script
COPY --chmod=755 requirements.txt health_proxy.py start.sh /

RUN apt-get update --yes --quiet \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet --no-install-recommends \
       software-properties-common gpg-agent build-essential apt-utils \
    && apt-get install --reinstall ca-certificates \
    && add-apt-repository --yes ppa:deadsnakes/ppa && apt update --yes --quiet \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet --no-install-recommends \
       python3.11 python3.11-dev python3.11-distutils python3.11-lib2to3 \
       python3.11-gdbm python3.11-tk bash curl \
    && ln -s /usr/bin/python3.11 /usr/bin/python \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 \
    && pip install -r /requirements.txt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set the entrypoint
ENTRYPOINT ["/bin/sh", "-c", "/start.sh"]
