#!/usr/bin/env node
"use strict";
//
// call-bases runtime server.
//
// A stateless, dependency-free (Node built-ins only) "reveal bytes up to f(now)"
// service. The global cursor is a pure function of wall-clock time:
//
//   current_index = floor((now - start_epoch) * rate)   clamped to [0, N]
//
// so every client renders the same state and the genome streams exactly once
// over the whole runtime. Data is read from the flat artifacts with positioned
// reads (pread); we never load the multi-GB files into memory and never expose
// anything beyond current_index. That single clamp is the entire enforcement of
// the "not retrievable at once" constraint.
//
const http = require("http");
const fs = require("fs");
const path = require("path");
const url = require("url");

// ---------------------------------------------------------------------------
// Config: defaults < config.json < environment.
// ---------------------------------------------------------------------------
function loadConfig() {
  const cfg = {
    artifactsDir: "./artifacts",
    webDir: "./web",
    listen: "8080",
    startEpoch: null, // unix seconds (number) or RFC3339 string
    rate: null, // bases per second
    runtimeSeconds: null, // alternative to rate
    tail: 4096, // bases sent to a fresh client for visual continuity
    tickMs: 250, // server reveal cadence
    pileup: null, // null = auto (enabled iff artifacts present)
  };
  const cfgPath = process.env.CALLBASES_CONFIG || path.join(process.cwd(), "config.json");
  if (fs.existsSync(cfgPath)) {
    Object.assign(cfg, JSON.parse(fs.readFileSync(cfgPath, "utf8")));
  }
  const env = process.env;
  if (env.CALLBASES_ARTIFACTS_DIR) cfg.artifactsDir = env.CALLBASES_ARTIFACTS_DIR;
  if (env.CALLBASES_WEB_DIR) cfg.webDir = env.CALLBASES_WEB_DIR;
  if (env.CALLBASES_LISTEN) cfg.listen = env.CALLBASES_LISTEN;
  if (env.CALLBASES_START_EPOCH) cfg.startEpoch = env.CALLBASES_START_EPOCH;
  if (env.CALLBASES_RATE) cfg.rate = Number(env.CALLBASES_RATE);
  if (env.CALLBASES_RUNTIME_SECONDS) cfg.runtimeSeconds = Number(env.CALLBASES_RUNTIME_SECONDS);
  if (env.CALLBASES_TAIL) cfg.tail = Number(env.CALLBASES_TAIL);
  if (env.CALLBASES_TICK_MS) cfg.tickMs = Number(env.CALLBASES_TICK_MS);
  if (env.CALLBASES_PILEUP) cfg.pileup = env.CALLBASES_PILEUP === "true";
  return cfg;
}

function parseEpochSeconds(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") return v;
  const s = String(v).trim();
  if (/^\d+(\.\d+)?$/.test(s)) return Number(s);
  const ms = Date.parse(s);
  if (Number.isNaN(ms)) throw new Error(`cannot parse start epoch: ${v}`);
  return ms / 1000;
}

// ---------------------------------------------------------------------------
// State: opened once at startup.
// ---------------------------------------------------------------------------
function openState(cfg) {
  const dir = cfg.artifactsDir;
  const meta = JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8"));
  const N = meta.n;

  const consensusFd = fs.openSync(path.join(dir, "consensus.bin"), "r");

  // pileup is auto-enabled iff the artifacts exist (unless force-disabled).
  const pileupBinPath = path.join(dir, "pileup.bin");
  const pileupIdxPath = path.join(dir, "pileup.idx");
  const havePileup = fs.existsSync(pileupBinPath) && fs.existsSync(pileupIdxPath);
  const pileupEnabled = cfg.pileup === false ? false : (cfg.pileup === true ? havePileup : havePileup);
  let pileupBinFd = null;
  let pileupIdxFd = null;
  if (pileupEnabled) {
    pileupBinFd = fs.openSync(pileupBinPath, "r");
    pileupIdxFd = fs.openSync(pileupIdxPath, "r");
  }

  // pacing: explicit config beats meta defaults; resolve to a single rate.
  const pacing = meta.pacing || {};
  const startEpoch = parseEpochSeconds(
    cfg.startEpoch != null ? cfg.startEpoch : pacing.start_epoch
  );
  if (startEpoch === null) throw new Error("no start epoch configured (config.startEpoch or meta.pacing.start_epoch)");

  let rate = cfg.rate != null ? cfg.rate : pacing.rate_bases_per_sec;
  const runtime = cfg.runtimeSeconds != null ? cfg.runtimeSeconds : pacing.runtime_seconds;
  if ((!rate || rate <= 0) && runtime && runtime > 0) rate = N / runtime;
  if (!rate || rate <= 0) throw new Error("no pacing configured (set rate or runtimeSeconds)");

  return {
    cfg,
    meta,
    N,
    consensusFd,
    pileupEnabled,
    pileupBinFd,
    pileupIdxFd,
    startEpoch,
    rate,
    tail: cfg.tail,
    tickMs: cfg.tickMs,
  };
}

function currentIndex(st, nowMs) {
  const elapsed = nowMs / 1000 - st.startEpoch;
  if (elapsed <= 0) return 0;
  const idx = Math.floor(elapsed * st.rate);
  return idx > st.N ? st.N : idx;
}

// Positioned read of [start, end) from a fd as a latin1 (raw ASCII) string.
function readBases(fd, start, end) {
  const len = end - start;
  if (len <= 0) return "";
  const buf = Buffer.allocUnsafe(len);
  let got = 0;
  while (got < len) {
    const n = fs.readSync(fd, buf, got, len - got, start + got);
    if (n <= 0) break;
    got += n;
  }
  return buf.toString("latin1", 0, got);
}

function contigFor(st, pos) {
  const c = st.meta.contigs;
  let lo = 0;
  let hi = c.length - 1;
  let ans = 0;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (c[mid].start <= pos) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  const ctg = c[ans];
  return { name: ctg.name, coord: pos - ctg.start + 1 };
}

// ---------------------------------------------------------------------------
// HTTP handlers.
// ---------------------------------------------------------------------------
function sseWrite(res, obj) {
  res.write(`data: ${JSON.stringify(obj)}\n\n`);
}

function handleStream(st, req, res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no", // belt-and-braces if a proxy buffers
  });

  let last = currentIndex(st, Date.now());
  const tailStart = Math.max(0, last - st.tail);
  sseWrite(res, {
    type: "hello",
    index: last,
    n: st.N,
    rate: st.rate,
    startEpoch: st.startEpoch,
    pileup: st.pileupEnabled,
    contigs: st.meta.contigs,
    tail: readBases(st.consensusFd, tailStart, last),
    tailStart,
  });

  let completeSent = false;
  const timer = setInterval(() => {
    const cur = currentIndex(st, Date.now());
    if (cur > last) {
      sseWrite(res, { type: "tick", index: cur, bases: readBases(st.consensusFd, last, cur) });
      last = cur;
    }
    if (cur >= st.N && !completeSent) {
      sseWrite(res, { type: "complete", index: st.N });
      completeSent = true;
    }
  }, st.tickMs);

  const stop = () => clearInterval(timer);
  req.on("close", stop);
  res.on("close", stop);
}

function handlePileup(st, query, res) {
  const send = (code, obj) => {
    res.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify(obj));
  };
  if (!st.pileupEnabled) return send(404, { error: "pileup not available" });
  const pos = Number.parseInt(query.pos, 10);
  if (!Number.isInteger(pos) || pos < 0 || pos >= st.N) return send(400, { error: "bad pos" });
  const cur = currentIndex(st, Date.now());
  if (pos > cur) return send(403, { error: "not yet revealed" }); // never leak the future

  const idxBuf = Buffer.allocUnsafe(16);
  fs.readSync(st.pileupIdxFd, idxBuf, 0, 16, pos * 8);
  const o1 = Number(idxBuf.readBigUInt64LE(0));
  const o2 = Number(idxBuf.readBigUInt64LE(8));
  const bases = readBases(st.pileupBinFd, o1, o2);
  const ref = readBases(st.consensusFd, pos, pos + 1);
  const { name, coord } = contigFor(st, pos);
  send(200, { pos, contig: name, coord, ref, depth: bases.length, bases });
}

function serveStatic(st, res) {
  const file = path.join(st.cfg.webDir, "index.html");
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("index.html not found");
      return;
    }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(data);
  });
}

function main() {
  const cfg = loadConfig();
  const st = openState(cfg);
  console.log(
    `call-bases: N=${st.N} rate=${st.rate.toFixed(3)} b/s start=${new Date(
      st.startEpoch * 1000
    ).toISOString()} pileup=${st.pileupEnabled}`
  );

  const server = http.createServer((req, res) => {
    const parsed = url.parse(req.url, true);
    if (req.method !== "GET") {
      res.writeHead(405);
      res.end();
      return;
    }
    if (parsed.pathname === "/stream") return handleStream(st, req, res);
    if (parsed.pathname === "/pileup") return handlePileup(st, parsed.query, res);
    if (parsed.pathname === "/" || parsed.pathname === "/index.html") return serveStatic(st, res);
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  });

  // listen target may be "PORT" or "HOST:PORT".
  const listen = String(cfg.listen);
  if (listen.includes(":")) {
    const [host, port] = listen.split(":");
    server.listen(Number(port), host || "0.0.0.0", () => console.log(`listening on ${listen}`));
  } else {
    server.listen(Number(listen), "0.0.0.0", () => console.log(`listening on :${listen}`));
  }
}

main();
