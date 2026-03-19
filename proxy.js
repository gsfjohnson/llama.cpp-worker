/**
 * Reverse proxy for llama.cpp server.
 *
 * Proxies all requests to the upstream llama-server, with special handling
 * for the /ping health-check endpoint used by RunPod's load balancer:
 *
 *   GET /ping  →  200 = healthy, 204 = initializing, other = unhealthy
 *
 * Supports two RunPod serverless modes (SERVERLESS_MODE env var):
 *
 *   "lb"    — Load balancer: all non-/ping requests proxied to llama-server
 *   "queue" — Queue: requests are RunPod job payloads with {id, input}
 *
 * When SERVERLESS_MODE is unset, auto-detects per request.
 */

const http = require('http');

const LLAMA_SERVER_HOST = process.env.LLAMA_SERVER_HOST || "127.0.0.1";
const LLAMA_SERVER_PORT = parseInt(process.env.LLAMA_ARG_PORT || "8080", 10);
const PORT_HEALTH = parseInt(process.env.PORT_HEALTH || "3000", 10);
const SERVERLESS_MODE = (process.env.SERVERLESS_MODE || "").toLowerCase();
const QUEUE_TIMEOUT = parseInt(process.env.QUEUE_TIMEOUT || "300000", 10);

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
function handleProxy(clientReq, clientRes, preBufferedBody) {
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

  if (preBufferedBody) {
    upstream.end(preBufferedBody);
  } else {
    clientReq.pipe(upstream);
  }
}

/**
 * Handle a RunPod queue job.
 *
 * Input format:
 *   { "id": "job-123", "input": { "messages": [...], ... } }
 *
 * Reserved keys in input (extracted before forwarding):
 *   endpoint — llama-server path (default: auto-detected)
 *   method   — HTTP method (default: POST)
 *
 * Auto-detection:
 *   - input has "messages" → /v1/chat/completions
 *   - input has "prompt"   → /v1/completions
 *   - otherwise            → /v1/chat/completions
 */
function handleQueueJob(_jobId, input, clientRes) {
  const { endpoint, method = "POST", ...body } = input;

  // Auto-detect endpoint if not specified
  const path = endpoint
    || (body.prompt && !body.messages ? "/v1/completions" : "/v1/chat/completions");

  const isStream = body.stream === true;
  const payload = JSON.stringify(body);

  const options = {
    hostname: LLAMA_SERVER_HOST,
    port: LLAMA_SERVER_PORT,
    path,
    method,
    timeout: QUEUE_TIMEOUT,
    headers: {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(payload),
    },
  };

  const upstream = http.request(options, (upstreamRes) => {
    if (upstreamRes.statusCode !== 200) {
      // Collect error body from upstream
      let chunks = [];
      upstreamRes.on("data", (c) => chunks.push(c));
      upstreamRes.on("end", () => {
        const errBody = Buffer.concat(chunks).toString();
        jsonResponse(clientRes, upstreamRes.statusCode, {
          error: `llama-server returned ${upstreamRes.statusCode}: ${errBody}`,
        });
      });
      return;
    }

    if (isStream) {
      // SSE passthrough — forward llama-server's SSE stream directly
      const headers = filterHeaders(upstreamRes.headers);
      clientRes.writeHead(200, headers);
      upstreamRes.pipe(clientRes);
    } else {
      // Buffer full response and wrap in RunPod output envelope
      let chunks = [];
      upstreamRes.on("data", (c) => chunks.push(c));
      upstreamRes.on("end", () => {
        try {
          const data = JSON.parse(Buffer.concat(chunks).toString());
          jsonResponse(clientRes, 200, { output: data });
        } catch {
          jsonResponse(clientRes, 200, {
            output: Buffer.concat(chunks).toString(),
          });
        }
      });
    }
  });

  upstream.on("error", () => {
    if (!clientRes.headersSent) {
      jsonResponse(clientRes, 503, { error: "llama-server unreachable" });
    }
  });

  upstream.on("timeout", () => {
    upstream.destroy();
    if (!clientRes.headersSent) {
      jsonResponse(clientRes, 504, { error: "request timed out" });
    }
  });

  upstream.end(payload);
}

/** Buffer the full request body and return it as a Buffer. */
function bufferBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
  });
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

  // /ping health check — always handled regardless of mode
  if (req.method === "GET" && req.url === "/ping") {
    res.on("finish", () => {
      const ms = Date.now() - start;
      console.log(`${res.statusCode} ${req.method} ${req.url} ${ms}ms in=${bytesIn} out=${bytesOut}`);
    });
    handlePing(res);
    return;
  }

  // Load balancer mode — proxy everything directly
  if (SERVERLESS_MODE === "lb") {
    res.on("finish", () => {
      const ms = Date.now() - start;
      console.log(`${res.statusCode} ${req.method} ${req.url} ${ms}ms in=${bytesIn} out=${bytesOut}`);
    });
    handleProxy(req, res);
    return;
  }

  // Queue mode or auto-detect — buffer body first
  bufferBody(req).then((rawBody) => {
    let job = null;
    try {
      job = JSON.parse(rawBody.toString());
    } catch {
      // Not valid JSON
    }

    const isQueueJob = job && typeof job === "object" && job.input && typeof job.input === "object";

    if (SERVERLESS_MODE === "queue") {
      // Forced queue mode — reject if not a valid queue job
      if (!isQueueJob) {
        res.on("finish", () => {
          const ms = Date.now() - start;
          console.log(`${res.statusCode} ${req.method} ${req.url} ${ms}ms in=${bytesIn} out=${bytesOut}`);
        });
        jsonResponse(res, 400, { error: "missing input field" });
        return;
      }
      const jobId = job.id || "local-test";
      res.on("finish", () => {
        const ms = Date.now() - start;
        console.log(`${res.statusCode} ${req.method} ${req.url} job=${jobId} ${ms}ms in=${bytesIn} out=${bytesOut}`);
      });
      handleQueueJob(jobId, job.input, res);
    } else if (isQueueJob) {
      // Auto-detect: looks like a queue job
      const jobId = job.id || "local-test";
      res.on("finish", () => {
        const ms = Date.now() - start;
        console.log(`${res.statusCode} ${req.method} ${req.url} job=${jobId} ${ms}ms in=${bytesIn} out=${bytesOut}`);
      });
      handleQueueJob(jobId, job.input, res);
    } else {
      // Auto-detect: not a queue job, proxy through
      res.on("finish", () => {
        const ms = Date.now() - start;
        console.log(`${res.statusCode} ${req.method} ${req.url} ${ms}ms in=${bytesIn} out=${bytesOut}`);
      });
      handleProxy(req, res, rawBody);
    }
  });
});

server.listen(PORT_HEALTH, "0.0.0.0", () => {
  const mode = SERVERLESS_MODE || "auto";
  console.log(`[proxy] Starting on port ${PORT_HEALTH} (mode: ${mode})`);
});
