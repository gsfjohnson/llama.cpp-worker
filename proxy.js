/**
 * Reverse proxy for llama.cpp server.
 *
 * Proxies all requests to the upstream llama-server, with special handling
 * for the /ping health-check endpoint used by RunPod's load balancer:
 *
 *   GET /ping  →  200 = healthy, 204 = initializing, other = unhealthy
 *
 * All other requests are forwarded to llama-server unmodified.
 */

const http = require('http');

const LLAMA_SERVER_HOST = process.env.LLAMA_SERVER_HOST || "127.0.0.1";
const LLAMA_SERVER_PORT = process.env.LLAMA_ARG_PORT || "8080";
const HEALTH_PORT = parseInt(process.env.PORT_HEALTH || "3000", 10);

const HOP_BY_HOP = new Set([
  "host", "connection", "keep-alive", "proxy-authenticate",
  "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
]);

function filterHeaders(raw) {
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!HOP_BY_HOP.has(k.toLowerCase())) out[k] = v;
  }
  return out;
}

function jsonResponse(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, { "content-type": "application/json" });
  res.end(body);
}

/** GET /ping — health check for RunPod load balancer. */
function handlePing(res) {
  const req = http.request(
    {
      hostname: LLAMA_SERVER_HOST,
      port: LLAMA_SERVER_PORT,
      path: "/health",
      method: "GET",
      timeout: 5000,
    },
    (upstream) => {
      let chunks = [];
      upstream.on("data", (c) => chunks.push(c));
      upstream.on("end", () => {
        if (upstream.statusCode !== 200) {
          res.writeHead(503);
          res.end();
          return;
        }
        try {
          const data = JSON.parse(Buffer.concat(chunks).toString());
          if (data.status === "ok") {
            jsonResponse(res, 200, { status: "healthy" });
          } else {
            jsonResponse(res, 204, { status: "initializing" });
          }
        } catch {
          jsonResponse(res, 204, { status: "initializing" });
        }
      });
    }
  );

  req.on("error", () => {
    jsonResponse(res, 204, { status: "initializing" });
  });

  req.on("timeout", () => {
    req.destroy();
    jsonResponse(res, 204, { status: "initializing" });
  });

  req.end();
}

/** Forward any non-/ping request to llama-server. */
function handleProxy(clientReq, clientRes) {
  const options = {
    hostname: LLAMA_SERVER_HOST,
    port: LLAMA_SERVER_PORT,
    path: clientReq.url,
    method: clientReq.method,
    headers: filterHeaders(clientReq.headers),
  };

  const upstream = http.request(options, (upstreamRes) => {
    const headers = filterHeaders(upstreamRes.headers);
    clientRes.writeHead(upstreamRes.statusCode, headers);
    upstreamRes.pipe(clientRes);
  });

  upstream.on("error", () => {
    if (!clientRes.headersSent) {
      clientRes.writeHead(502);
      clientRes.end("upstream unreachable");
    }
  });

  clientReq.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const start = Date.now();
  let bytesIn = 0;
  req.on("data", (chunk) => { bytesIn += chunk.length; });

  const origWrite = res.write.bind(res);
  const origEnd = res.end.bind(res);
  let bytesOut = 0;
  res.write = (chunk, ...args) => {
    if (chunk) bytesOut += typeof chunk === "string" ? Buffer.byteLength(chunk) : chunk.length;
    return origWrite(chunk, ...args);
  };
  res.end = (chunk, ...args) => {
    if (chunk) bytesOut += typeof chunk === "string" ? Buffer.byteLength(chunk) : chunk.length;
    return origEnd(chunk, ...args);
  };

  res.on("finish", () => {
    const ms = Date.now() - start;
    console.log(`${res.statusCode} ${req.method} ${req.url} ${ms}ms in=${bytesIn} out=${bytesOut}`);
  });

  if (req.method === "GET" && req.url === "/ping") {
    handlePing(res);
  } else {
    handleProxy(req, res);
  }
});

server.listen(HEALTH_PORT, "0.0.0.0", () => {
  console.log(`[proxy] Starting on port ${HEALTH_PORT}`);
});
