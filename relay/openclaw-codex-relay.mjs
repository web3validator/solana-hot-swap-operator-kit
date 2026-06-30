import http from "node:http";
import { execFile } from "node:child_process";
import { homedir } from "node:os";

const HOME_DIR = process.env.HOME || homedir();
const PORT = Number(process.env.PORT || 20129);
const HOST = process.env.HOST || "0.0.0.0";
const TOKEN = process.env.OPENCLAW_CODEX_RELAY_TOKEN || "";
const OPENCLAW_BIN = process.env.OPENCLAW_BIN || "openclaw";
const OPENCLAW_WORKSPACE = process.env.OPENCLAW_WORKSPACE || HOME_DIR + "/.openclaw/workspace";
const MODEL = process.env.OPENCLAW_CODEX_RELAY_MODEL || "openai/gpt-5.5";
const THINKING = process.env.OPENCLAW_CODEX_RELAY_THINKING || "low";
const REQUEST_TIMEOUT_MS = Number(process.env.OPENCLAW_CODEX_RELAY_TIMEOUT_MS || 180000);
const MAX_BODY_BYTES = Number(process.env.OPENCLAW_CODEX_RELAY_MAX_BODY_BYTES || 1024 * 1024);
const ALLOWLIST = new Set(
  (process.env.OPENCLAW_CODEX_RELAY_ALLOWLIST || "127.0.0.1,::1")
    .split(",")
    .map((item) => normalizeIp(item.trim()))
    .filter(Boolean),
);

let queue = Promise.resolve();

function normalizeIp(ip) {
  if (!ip) return "";
  if (ip.startsWith("::ffff:")) return ip.slice("::ffff:".length);
  return ip;
}

function remoteIp(req) {
  return normalizeIp(req.socket.remoteAddress || "");
}

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function requireAccess(req, res) {
  const ip = remoteIp(req);
  if (ALLOWLIST.size > 0 && !ALLOWLIST.has(ip)) {
    sendJson(res, 403, { error: { message: "Forbidden", type: "forbidden" } });
    return false;
  }
  if (TOKEN) {
    const expected = "Bearer " + TOKEN;
    if (req.headers.authorization !== expected) {
      sendJson(res, 401, { error: { message: "Unauthorized", type: "unauthorized" } });
      return false;
    }
  }
  return true;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("Request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function contentToText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!part || typeof part !== "object") return "";
        if (part.type === "text") return part.text || "";
        if (part.type === "input_text") return part.text || "";
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function buildPrompt(payload) {
  const lines = [];
  lines.push("You are serving an OpenAI-compatible chat completion request.");
  if (payload.response_format?.type === "json_object") {
    lines.push("Return exactly one valid JSON object. No markdown, no prose outside JSON.");
  }
  if (Number.isFinite(payload.max_completion_tokens)) {
    lines.push("Target maximum completion tokens: " + payload.max_completion_tokens + ".");
  }
  lines.push("");
  lines.push("Conversation:");
  for (const message of payload.messages || []) {
    const role = typeof message.role === "string" ? message.role : "user";
    const text = contentToText(message.content);
    if (!text) continue;
    lines.push("\n[" + role.toUpperCase() + "]\n" + text);
  }
  lines.push("\n[ASSISTANT]");
  return lines.join("\n");
}

function parseOpenClawJson(stdout) {
  const start = stdout.indexOf("{");
  const end = stdout.lastIndexOf("}");
  if (start < 0 || end <= start) {
    throw new Error("OpenClaw returned non-JSON output: " + stdout.slice(0, 500));
  }
  return JSON.parse(stdout.slice(start, end + 1));
}

function textFromOpenClawResult(parsed) {
  if (typeof parsed.text === "string") return parsed.text.trim();
  if (typeof parsed.output_text === "string") return parsed.output_text.trim();
  if (Array.isArray(parsed.outputs)) {
    return parsed.outputs.map((item) => item?.text || "").join("\n").trim();
  }
  if (Array.isArray(parsed.output)) {
    return parsed.output
      .flatMap((item) => item?.content || [])
      .map((item) => item?.text || "")
      .join("\n")
      .trim();
  }
  return "";
}

function runOpenClaw(prompt) {
  return new Promise((resolve, reject) => {
    const args = [
      "infer",
      "model",
      "run",
      "--local",
      "--json",
      "--model",
      MODEL,
      "--thinking",
      THINKING,
      "--prompt",
      prompt,
    ];
    execFile(
      OPENCLAW_BIN,
      args,
      {
        cwd: OPENCLAW_WORKSPACE,
        timeout: REQUEST_TIMEOUT_MS,
        maxBuffer: 10 * 1024 * 1024,
        env: {
          ...process.env,
          HOME: HOME_DIR,
        },
      },
      (error, stdout, stderr) => {
        if (error) {
          const detail = stderr || stdout || error.message;
          reject(new Error("OpenClaw inference failed: " + detail.slice(0, 2000)));
          return;
        }
        try {
          const parsed = parseOpenClawJson(stdout);
          const text = textFromOpenClawResult(parsed);
          if (!text) throw new Error("OpenClaw returned empty text");
          resolve({ text, raw: parsed });
        } catch (parseError) {
          reject(parseError);
        }
      },
    );
  });
}

async function enqueue(fn) {
  const previous = queue;
  let release;
  queue = new Promise((resolve) => {
    release = resolve;
  });
  await previous.catch(() => undefined);
  try {
    return await fn();
  } finally {
    release();
  }
}

async function handleChatCompletions(req, res) {
  if (!requireAccess(req, res)) return;
  if (req.method !== "POST") {
    sendJson(res, 405, { error: { message: "Method not allowed", type: "method_not_allowed" } });
    return;
  }
  let payload;
  try {
    payload = JSON.parse(await readBody(req));
  } catch (error) {
    sendJson(res, 400, { error: { message: error.message, type: "invalid_request_error" } });
    return;
  }
  if (!Array.isArray(payload.messages)) {
    sendJson(res, 400, {
      error: { message: "messages must be an array", type: "invalid_request_error" },
    });
    return;
  }
  if (payload.stream) {
    sendJson(res, 400, {
      error: { message: "stream=true is not supported by this relay", type: "invalid_request_error" },
    });
    return;
  }

  const started = Date.now();
  try {
    const prompt = buildPrompt(payload);
    const result = await enqueue(() => runOpenClaw(prompt));
    sendJson(res, 200, {
      id: "chatcmpl-openclaw-" + Date.now().toString(36),
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: payload.model || MODEL,
      choices: [
        {
          index: 0,
          message: { role: "assistant", content: result.text },
          finish_reason: "stop",
        },
      ],
      usage: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: result.raw?.usage?.totalTokens || result.raw?.usage?.total_tokens || 0,
      },
      relay: {
        provider: "openclaw",
        model: MODEL,
        thinking: THINKING,
        elapsed_ms: Date.now() - started,
      },
    });
  } catch (error) {
    console.error("[relay] " + new Date().toISOString() + " request failed:", error);
    sendJson(res, 502, {
      error: {
        message: error instanceof Error ? error.message : String(error),
        type: "upstream_error",
      },
    });
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", "http://" + (req.headers.host || "localhost"));
  if (url.pathname === "/health") {
    sendJson(res, 200, { ok: true, model: MODEL, thinking: THINKING });
    return;
  }
  if (url.pathname === "/v1/models") {
    if (!requireAccess(req, res)) return;
    sendJson(res, 200, {
      object: "list",
      data: [{ id: MODEL.split("/").pop() || MODEL, object: "model", owned_by: "openclaw" }],
    });
    return;
  }
  if (url.pathname === "/v1/chat/completions") {
    await handleChatCompletions(req, res);
    return;
  }
  sendJson(res, 404, { error: { message: "Not found", type: "not_found" } });
});

server.listen(PORT, HOST, () => {
  console.log(
    "[relay] listening on " +
      HOST +
      ":" +
      PORT +
      "; model=" +
      MODEL +
      "; thinking=" +
      THINKING +
      "; workspace=" +
      OPENCLAW_WORKSPACE +
      "; allowlist=" +
      [...ALLOWLIST].join(","),
  );
});
