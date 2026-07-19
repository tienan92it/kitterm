#!/usr/bin/env node
/**
 * Head-to-head bench: kitterm (binary WS) vs localterm (JSON input + raw output).
 * Requires both daemons running (default 3418 / 3417).
 *
 * Usage: node Bench/compare-localterm.mjs
 * Prereq: npm install --prefix Bench ws@8
 */

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const WebSocket = require("ws");

const KITTERM_PORT = Number(process.env.KITTERM_PORT ?? 3418);
const LOCALTERM_PORT = Number(process.env.LOCALTERM_PORT ?? 3417);
const ECHO_ROUNDS = 80;
const TUI_FRAMES = 80;
const TUI_COLS = 80;
const TUI_ROWS = 24;
const BURST_BYTES = 8 * 1024 * 1024;
const SLOW_BYTES = 2 * 1024 * 1024;
const SLOW_DELAY_MS = 5;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowMs = () => performance.now();

const percentile = (sorted, p) => {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))];
};

const summaryMs = (samples) => {
  const s = [...samples].sort((a, b) => a - b);
  return {
    n: s.length,
    min: s[0],
    p50: percentile(s, 0.5),
    p95: percentile(s, 0.95),
    p99: percentile(s, 0.99),
    max: s[s.length - 1],
  };
};

const fmt = (n, digits = 2) => Number(n).toFixed(digits);

class BenchClient {
  constructor(kind, port) {
    this.kind = kind;
    this.port = port;
    this.ws = null;
    this.buf = Buffer.alloc(0);
    this.bytesReceived = 0;
    this.outputFrames = 0;
    this.maxOutputFrameBytes = 0;
    this.closedReason = null;
    this.receiveDelayMs = 0;
    this._waiters = [];
    this._queue = [];
  }

  async connect() {
    const url = `ws://127.0.0.1:${this.port}/ws`;
    this.ws = new WebSocket(url, {
      headers: {
        Host: `127.0.0.1:${this.port}`,
        Origin: `http://127.0.0.1:${this.port}`,
      },
    });

    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`${this.kind}: connect timeout`)), 5000);
      this.ws.once("open", () => {
        clearTimeout(t);
        resolve();
      });
      this.ws.once("error", (err) => {
        clearTimeout(t);
        reject(new Error(`${this.kind}: connect error: ${err.message}`));
      });
      this.ws.once("unexpected-response", (_req, res) => {
        clearTimeout(t);
        reject(new Error(`${this.kind}: unexpected HTTP ${res.statusCode}`));
      });
    });

    this.ws.on("message", async (data, isBinary) => {
      if (this.receiveDelayMs > 0) await sleep(this.receiveDelayMs);
      let payload;
      if (!isBinary) {
        // localterm control JSON — ignore for throughput metrics
        return;
      }
      const raw = Buffer.isBuffer(data) ? data : Buffer.from(data);
      if (this.kind === "kitterm") {
        if (raw.length === 0) return;
        const opcode = raw[0];
        if (opcode !== 0) return; // only count PTY output
        payload = raw.subarray(1);
      } else {
        payload = raw; // localterm: raw PTY bytes
      }
      this.bytesReceived += payload.length;
      this.outputFrames += 1;
      this.maxOutputFrameBytes = Math.max(this.maxOutputFrameBytes, payload.length);
      this.buf = Buffer.concat([this.buf, payload]);
      this._flushWaiters();
    });

    this.ws.on("close", (code, reason) => {
      this.closedReason = `closed code=${code} reason=${reason?.toString?.() || ""}`;
      for (const w of this._waiters) w.reject(new Error(this.closedReason));
      this._waiters = [];
    });

    await sleep(150);
  }

  close() {
    try {
      this.ws?.close();
    } catch {
      /* ignore */
    }
  }

  clear() {
    this.buf = Buffer.alloc(0);
  }

  sendInput(text) {
    if (this.kind === "kitterm") {
      const payload = Buffer.from(text, "utf8");
      const frame = Buffer.alloc(1 + payload.length);
      frame[0] = 0;
      payload.copy(frame, 1);
      this.ws.send(frame);
    } else {
      this.ws.send(JSON.stringify({ type: "input", data: text }));
    }
  }

  sendResize(cols, rows) {
    if (this.kind === "kitterm") {
      const frame = Buffer.alloc(5);
      frame[0] = 1;
      frame.writeUInt16BE(cols, 1);
      frame.writeUInt16BE(rows, 3);
      this.ws.send(frame);
    } else {
      this.ws.send(JSON.stringify({ type: "resize", cols, rows }));
    }
  }

  sendRawInputBytes(bytes) {
    if (this.kind === "kitterm") {
      const frame = Buffer.alloc(1 + bytes.length);
      frame[0] = 0;
      bytes.copy(frame, 1);
      this.ws.send(frame);
    } else {
      this.ws.send(JSON.stringify({ type: "input", data: bytes.toString("binary") }));
    }
  }

  waitFor(needle, timeoutMs = 15000) {
    const needleBuf = Buffer.isBuffer(needle) ? needle : Buffer.from(needle);
    return new Promise((resolve, reject) => {
      const tryFind = () => {
        const idx = this.buf.indexOf(needleBuf);
        if (idx >= 0) {
          resolve(idx);
          return true;
        }
        return false;
      };
      if (tryFind()) return;
      const timer = setTimeout(() => {
        this._waiters = this._waiters.filter((w) => w !== entry);
        reject(new Error(`${this.kind}: timeout waiting for ${needleBuf.toString()}`));
      }, timeoutMs);
      const entry = {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
        tryFind,
      };
      this._waiters.push(entry);
    });
  }

  _flushWaiters() {
    const still = [];
    for (const w of this._waiters) {
      if (!w.tryFind()) still.push(w);
    }
    this._waiters = still;
  }

  async drainQuiet(quietMs = 200, maxMs = 2000) {
    const start = nowMs();
    let last = this.bytesReceived;
    let lastChange = nowMs();
    while (nowMs() - start < maxMs) {
      await sleep(50);
      if (this.bytesReceived !== last) {
        last = this.bytesReceived;
        lastChange = nowMs();
      } else if (nowMs() - lastChange >= quietMs) {
        break;
      }
    }
  }
}

async function awaitShellReady(client) {
  client.sendResize(80, 40);
  await client.drainQuiet(300, 3000);
  client.clear();
  const marker = `READY_${Math.floor(Math.random() * 9000 + 1000)}`;
  client.sendInput(`printf '%s\\n' '${marker}'\n`);
  await client.waitFor(marker, 10000);
  await client.drainQuiet(150, 1000);
  client.clear();
}

async function interactiveEcho(kind, port) {
  const client = new BenchClient(kind, port);
  try {
    await client.connect();
    await awaitShellReady(client);
    client.sendInput("exec cat\n");
    await client.drainQuiet(200, 2000);
    client.clear();

    const samples = [];
    for (let i = 0; i < ECHO_ROUNDS; i++) {
      const byte = Buffer.from([0x41 + (i % 26)]);
      const t0 = nowMs();
      client.sendRawInputBytes(byte);
      await client.waitFor(byte, 3000);
      samples.push(nowMs() - t0);
    }
    const s = summaryMs(samples);
    return {
      scenario: "interactive-echo",
      kind,
      ok: s.p95 < 50,
      ...s,
      outputFrames: client.outputFrames,
      maxFrame: client.maxOutputFrameBytes,
    };
  } finally {
    client.close();
  }
}

async function tuiRedraw(kind, port) {
  const client = new BenchClient(kind, port);
  try {
    await client.connect();
    await awaitShellReady(client);
    const done = "KITTERM_TUI_DONE";
    const script = `i=0
while [ "$i" -lt ${TUI_FRAMES} ]; do
  printf '\\033[H\\033[J'
  r=0
  while [ "$r" -lt ${TUI_ROWS} ]; do
    printf '%0${TUI_COLS}d\\n' "$i"
    r=$((r+1))
  done
  i=$((i+1))
done
printf '${done}\\n'
`;
    const before = client.bytesReceived;
    const t0 = nowMs();
    client.sendInput(script);
    await client.waitFor(done, 60000);
    const elapsedSec = (nowMs() - t0) / 1000;
    const bytes = client.bytesReceived - before;
    const mbps = elapsedSec > 0 ? bytes / 1_000_000 / elapsedSec : 0;
    const approx = 8 + TUI_ROWS * (TUI_COLS + 1);
    const ok = bytes > (TUI_FRAMES * approx) / 3 && !client.closedReason?.includes("exited");
    return {
      scenario: "TUI-redraw",
      kind,
      ok,
      bytes,
      elapsedSec,
      mbps,
      outputFrames: client.outputFrames,
      maxFrame: client.maxOutputFrameBytes,
    };
  } finally {
    client.close();
  }
}

async function largeBurst(kind, port) {
  const fast = new BenchClient(kind, port);
  let fastResult;
  try {
    await fast.connect();
    await awaitShellReady(fast);
    const before = fast.bytesReceived;
    const t0 = nowMs();
    fast.sendInput(
      `dd if=/dev/zero bs=65536 count=${BURST_BYTES / 65536} status=none; printf 'KITTERM_BURST_DONE\\n'\n`,
    );
    await fast.waitFor("KITTERM_BURST_DONE", 90000);
    const elapsedSec = (nowMs() - t0) / 1000;
    const bytes = fast.bytesReceived - before;
    const mbps = elapsedSec > 0 ? bytes / 1_000_000 / elapsedSec : 0;
    const batchSane = fast.maxOutputFrameBytes > 0 && fast.maxOutputFrameBytes <= 256 * 1024;
    fastResult = {
      bytes,
      elapsedSec,
      mbps,
      maxFrame: fast.maxOutputFrameBytes,
      frames: fast.outputFrames,
      ok: bytes >= BURST_BYTES && batchSane,
    };
  } finally {
    fast.close();
  }

  const slow = new BenchClient(kind, port);
  slow.receiveDelayMs = SLOW_DELAY_MS;
  let slowResult;
  try {
    await slow.connect();
    await awaitShellReady(slow);
    const before = slow.bytesReceived;
    slow.sendInput(
      `dd if=/dev/zero bs=65536 count=${SLOW_BYTES / 65536} status=none; printf 'KITTERM_SLOW_DONE\\n'\n`,
    );
    await slow.waitFor("KITTERM_SLOW_DONE", 180000);
    const bytes = slow.bytesReceived - before;
    const dropped =
      slow.closedReason?.includes("exited") ||
      slow.closedReason?.includes("4429") ||
      slow.closedReason?.includes("backpressure");
    slowResult = {
      bytes,
      reason: slow.closedReason ?? "none",
      ok: bytes >= SLOW_BYTES && !dropped,
    };
  } finally {
    slow.close();
  }

  return {
    scenario: "large-burst",
    kind,
    ok: fastResult.ok && slowResult.ok,
    fast: fastResult,
    slow: slowResult,
  };
}

async function health(port, hostLabel) {
  const res = await fetch(`http://127.0.0.1:${port}/api/health`, {
    headers: { Host: `127.0.0.1:${port}` },
  });
  if (!res.ok) throw new Error(`${hostLabel}: health HTTP ${res.status}`);
  return res.json();
}

async function runOne(kind, port) {
  console.log(`\n======== ${kind} :${port} ========`);
  const echo = await interactiveEcho(kind, port);
  console.log(
    `interactive-echo  p50=${fmt(echo.p50)}ms p95=${fmt(echo.p95)}ms p99=${fmt(echo.p99)}ms max=${fmt(echo.max)}ms frames=${echo.outputFrames} maxFrame=${echo.maxFrame}B  ${echo.ok ? "PASS" : "FAIL"}`,
  );
  const tui = await tuiRedraw(kind, port);
  console.log(
    `TUI-redraw        ${tui.bytes} B in ${fmt(tui.elapsedSec, 3)}s → ${fmt(tui.mbps)} MB/s  maxFrame=${tui.maxFrame}B  ${tui.ok ? "PASS" : "FAIL"}`,
  );
  const burst = await largeBurst(kind, port);
  console.log(
    `large-burst fast  ${burst.fast.bytes} B in ${fmt(burst.fast.elapsedSec, 3)}s → ${fmt(burst.fast.mbps)} MB/s  maxFrame=${burst.fast.maxFrame}B  ${burst.fast.ok ? "PASS" : "FAIL"}`,
  );
  console.log(
    `large-burst slow  ${burst.slow.bytes} B reason=${burst.slow.reason}  ${burst.slow.ok ? "PASS" : "FAIL"}`,
  );
  return { kind, port, echo, tui, burst, ok: echo.ok && tui.ok && burst.ok };
}

function compare(a, b, higherBetter, unit) {
  const delta = b - a;
  const pct = a === 0 ? 0 : (delta / a) * 100;
  const winner =
    Math.abs(pct) < 5 ? "≈ tie" : higherBetter ? (b > a ? "localterm" : "kitterm") : b < a ? "localterm" : "kitterm";
  return { a, b, delta, pct, winner, unit };
}

async function main() {
  const ktHealth = await health(KITTERM_PORT, "kitterm");
  const ltHealth = await health(LOCALTERM_PORT, "localterm");
  console.log("health kitterm  ", ktHealth);
  console.log("health localterm", ltHealth);
  console.log(`echo rounds=${ECHO_ROUNDS}  tui frames=${TUI_FRAMES}  burst=${BURST_BYTES}B`);

  // Alternate order bias: run kitterm first, then localterm, then reverse echo once? Keep fixed order; note it.
  const kitterm = await runOne("kitterm", KITTERM_PORT);
  await sleep(500);
  const localterm = await runOne("localterm", LOCALTERM_PORT);

  console.log("\n======== COMPARISON ========");
  const rows = [
    [
      "echo p50 (ms)",
      compare(kitterm.echo.p50, localterm.echo.p50, false, "ms"),
    ],
    [
      "echo p95 (ms)",
      compare(kitterm.echo.p95, localterm.echo.p95, false, "ms"),
    ],
    [
      "TUI MB/s",
      compare(kitterm.tui.mbps, localterm.tui.mbps, true, "MB/s"),
    ],
    [
      "burst MB/s",
      compare(kitterm.burst.fast.mbps, localterm.burst.fast.mbps, true, "MB/s"),
    ],
  ];

  for (const [label, c] of rows) {
    console.log(
      `${label.padEnd(14)}  kitterm=${fmt(c.a)}  localterm=${fmt(c.b)}  Δ=${fmt(c.delta)} (${fmt(c.pct)}%)  → ${c.winner}`,
    );
  }
  console.log(
    `\nOverall gates: kitterm ${kitterm.ok ? "PASS" : "FAIL"} | localterm ${localterm.ok ? "PASS" : "FAIL"}`,
  );
  console.log(
    "Note: browser paint is not measured — this is daemon↔client WS+PTY only. ±5% treated as tie.",
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
