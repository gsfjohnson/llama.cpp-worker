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