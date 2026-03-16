"""
Reverse proxy for llama.cpp server.

Proxies all requests to the upstream llama-server, with special handling
for the /ping health-check endpoint used by RunPod's load balancer:

  GET /ping  →  200 = healthy, 204 = initializing, other = unhealthy

All other requests are forwarded to llama-server unmodified.
"""

import os
import httpx
from fastapi import FastAPI, Request, Response

app = FastAPI()

LLAMA_SERVER_HOST = os.getenv("LLAMA_SERVER_HOST", "127.0.0.1")
LLAMA_SERVER_PORT = os.getenv("LLAMA_ARG_PORT", "8080")
LLAMA_BASE_URL = f"http://{LLAMA_SERVER_HOST}:{LLAMA_SERVER_PORT}"
LLAMA_HEALTH_URL = f"{LLAMA_BASE_URL}/health"

HOP_BY_HOP_HEADERS = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
})


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


@app.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
)
async def proxy(request: Request, path: str):
    """Forward any non-/ping request to llama-server."""
    url = f"{LLAMA_BASE_URL}/{path}"
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ("host",) | HOP_BY_HOP_HEADERS
    }
    body = await request.body()

    try:
        async with httpx.AsyncClient(timeout=None) as client:
            resp = await client.request(
                method=request.method,
                url=url,
                headers=headers,
                params=dict(request.query_params),
                content=body if body else None,
            )
    except httpx.ConnectError:
        return Response(status_code=502, content="upstream unreachable")

    response_headers = {
        k: v for k, v in resp.headers.items()
        if k.lower() not in HOP_BY_HOP_HEADERS
    }
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        headers=response_headers,
    )


if __name__ == "__main__":
    import uvicorn

    health_port = int(os.getenv("PORT_HEALTH", "3000"))
    print(f"[health_proxy] Starting on port {health_port}")
    uvicorn.run(app, host="0.0.0.0", port=health_port)