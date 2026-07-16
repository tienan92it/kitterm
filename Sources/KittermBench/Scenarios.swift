import Foundation
import KittermProtocol

struct ScenarioResult {
    var name: String
    var ok: Bool
    var lines: [String]
}

enum Scenarios {
    static func run(_ name: String, port: Int) async throws -> ScenarioResult {
        switch name {
        case "interactive-echo":
            return try await interactiveEcho(port: port)
        case "TUI-redraw", "tui-redraw":
            return try await tuiRedraw(port: port)
        case "large-burst":
            return try await largeBurst(port: port)
        case "all":
            var combined = ScenarioResult(name: "all", ok: true, lines: [])
            for scenario in ["interactive-echo", "TUI-redraw", "large-burst"] {
                let result = try await run(scenario, port: port)
                combined.ok = combined.ok && result.ok
                combined.lines.append("--- \(result.name) ---")
                combined.lines.append(contentsOf: result.lines)
                combined.lines.append(result.ok ? "PASS" : "FAIL")
            }
            return combined
        default:
            throw BenchError.unexpected("unknown scenario: \(name)")
        }
    }

    /// Wait until the login shell accepts commands.
    private static func awaitShellReady(_ client: WSClient) async throws {
        try client.sendResize(cols: 80, rows: 40)
        await client.drainQuiet(quietMs: 300, maxMs: 3_000)
        client.clearOutputBuffer()
        // Unique marker avoids matching shell noise.
        let marker = "KITTERM_READY_\(UInt32.random(in: 1000...9999))"
        try client.sendInput("printf '%s\\n' '\(marker)'\n")
        _ = try client.waitFor(Data(marker.utf8), timeoutMs: 8_000)
        await client.drainQuiet(quietMs: 150, maxMs: 1_000)
        client.clearOutputBuffer()
    }

    // MARK: - interactive-echo

    /// Keystroke → echoed byte RTT via `exec cat` (no shell echo coalescing).
    private static func interactiveEcho(port: Int) async throws -> ScenarioResult {
        let client = WSClient(port: port)
        defer { client.close() }
        try await client.connect()
        try await awaitShellReady(client)

        // Replace login shell with raw cat so each byte echoes once.
        try client.sendInput("exec cat\n")
        await client.drainQuiet(quietMs: 200, maxMs: 2_000)
        client.clearOutputBuffer()

        let rounds = 80
        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(rounds)

        for i in 0..<rounds {
            let byte = UInt8(0x41 + (i % 26)) // A-Z cycling
            let needle = Data([byte])
            let t0 = DispatchTime.now().uptimeNanoseconds
            try client.send(.input(needle))
            _ = try client.waitFor(needle, timeoutMs: 2_000)
            let t1 = DispatchTime.now().uptimeNanoseconds
            samplesMs.append(Double(t1 - t0) / 1_000_000)
        }

        let p95 = Stats.percentile(samplesMs.sorted(), 0.95)
        let ok = p95 < 50
        return ScenarioResult(
            name: "interactive-echo",
            ok: ok,
            lines: [
                Stats.summaryMs(samplesMs),
                String(format: "outputFrames=%d maxFrame=%d B", client.outputFrames, client.maxOutputFrameBytes),
                "gate: p95 < 50ms → \(ok ? "ok" : "miss")",
            ]
        )
    }

    // MARK: - TUI-redraw

    /// Synthetic full-screen ANSI redraw flood; measure daemon→client throughput.
    private static func tuiRedraw(port: Int) async throws -> ScenarioResult {
        let client = WSClient(port: port)
        defer { client.close() }
        try await client.connect()
        try await awaitShellReady(client)

        let frames = 80
        let cols = 80
        let rows = 24
        // Pure sh loop — no python dependency / quoting issues.
        let script = """
        i=0
        while [ "$i" -lt \(frames) ]; do
          printf '\\033[H\\033[J'
          r=0
          while [ "$r" -lt \(rows) ]; do
            printf '%0\(cols)d\\n' "$i"
            r=$((r+1))
          done
          i=$((i+1))
        done
        printf 'KITTERM_TUI_DONE\\n'

        """
        let before = client.bytesReceived
        let t0 = DispatchTime.now().uptimeNanoseconds
        try client.sendInput(script)
        _ = try client.waitFor(Data("KITTERM_TUI_DONE".utf8), timeoutMs: 60_000)
        let t1 = DispatchTime.now().uptimeNanoseconds

        let bytes = client.bytesReceived - before
        let elapsedSec = Double(t1 - t0) / 1_000_000_000
        let mbps = elapsedSec > 0 ? (Double(bytes) / 1_000_000) / elapsedSec : 0
        let approxPerFrame = 8 + rows * (cols + 1)
        let droppedEarly = (client.closedReason?.contains("exited") == true)
        let ok = bytes > frames * approxPerFrame / 3 && !droppedEarly
        return ScenarioResult(
            name: "TUI-redraw",
            ok: ok,
            lines: [
                String(format: "bytes=%d frames=%d elapsed=%.3fs throughput=%.2f MB/s", bytes, frames, elapsedSec, mbps),
                String(format: "outputFrames=%d maxFrame=%d B", client.outputFrames, client.maxOutputFrameBytes),
                "gate: sustained redraw without session drop → \(ok ? "ok" : "miss")",
            ]
        )
    }

    // MARK: - large-burst

    /// Megabyte flood + slow-drain backpressure survival check.
    private static func largeBurst(port: Int) async throws -> ScenarioResult {
        var lines: [String] = []

        // Pass A: fast client drains a ~8MB burst.
        let fast = WSClient(port: port)
        defer { fast.close() }
        try await fast.connect()
        try await awaitShellReady(fast)

        let burstBytes = 8 * 1024 * 1024
        let before = fast.bytesReceived
        let t0 = DispatchTime.now().uptimeNanoseconds
        try fast.sendInput(
            "dd if=/dev/zero bs=65536 count=\(burstBytes / 65536) status=none; printf 'KITTERM_BURST_DONE\\n'\n"
        )
        _ = try fast.waitFor(Data("KITTERM_BURST_DONE".utf8), timeoutMs: 90_000)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let got = fast.bytesReceived - before
        let elapsedSec = Double(t1 - t0) / 1_000_000_000
        let mbps = elapsedSec > 0 ? (Double(got) / 1_000_000) / elapsedSec : 0
        lines.append(String(
            format: "fast-drain: bytes=%d elapsed=%.3fs throughput=%.2f MB/s maxFrame=%d B frames=%d",
            got, elapsedSec, mbps, fast.maxOutputFrameBytes, fast.outputFrames
        ))
        let batchSane = fast.maxOutputFrameBytes > 0 && fast.maxOutputFrameBytes <= 256 * 1024
        let fastOK = got >= burstBytes && batchSane
        lines.append(
            "gate: received ≥ \(burstBytes) B and maxFrame ≤ 256KiB → \(fastOK ? "ok" : "miss") (targetBatch=\(KittermConstants.outputBatchMaxBytes) B)"
        )

        // Pass B: slow-drain client; PTY pause/resume should keep the session alive.
        let slow = WSClient(port: port)
        defer { slow.close() }
        slow.receiveDelayNs = 5_000_000 // 5ms between receives
        try await slow.connect()
        try await awaitShellReady(slow)
        let slowTarget = 2 * 1024 * 1024
        let slowBefore = slow.bytesReceived
        try slow.sendInput(
            "dd if=/dev/zero bs=65536 count=\(slowTarget / 65536) status=none; printf 'KITTERM_SLOW_DONE\\n'\n"
        )
        _ = try slow.waitFor(Data("KITTERM_SLOW_DONE".utf8), timeoutMs: 180_000)
        let slowGot = slow.bytesReceived - slowBefore
        let slowDropped = slow.closedReason?.contains("exited") == true
            || slow.closedReason?.contains("4429") == true
        let slowOK = slowGot >= slowTarget && !slowDropped
        lines.append(String(
            format: "slow-drain: bytes=%d (target=%d) reason=%@",
            slowGot, slowTarget, slow.closedReason ?? "none"
        ))
        lines.append("gate: session survives slow drain (pause/resume) → \(slowOK ? "ok" : "miss")")

        return ScenarioResult(
            name: "large-burst",
            ok: fastOK && slowOK,
            lines: lines
        )
    }
}
