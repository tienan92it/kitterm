import Foundation
import KittermProtocol
import NIOCore

/// Coalesces PTY output: ~2ms / 64KB window; immediate flush when quiet.
final class OutputBatcher {
    private let eventLoop: EventLoop
    private var buffer = ByteBuffer()
    private var scheduledFlush: Scheduled<Void>?
    /// Distant past so the first chunk flushes immediately (interactive path).
    private var lastActivity = NIODeadline.now() - .seconds(60)
    private let onFlush: (ByteBuffer) -> Void
    private var closed = false

    init(eventLoop: EventLoop, onFlush: @escaping (ByteBuffer) -> Void) {
        self.eventLoop = eventLoop
        self.onFlush = onFlush
    }

    func append(_ data: Data) {
        eventLoop.assertInEventLoop()
        guard !closed, !data.isEmpty else { return }

        let now = NIODeadline.now()
        let quietGap = KittermConstants.outputBatchWindowMs * 2
        let wasQuiet = now - lastActivity > .milliseconds(Int64(quietGap))
        lastActivity = now

        buffer.writeBytes(data)

        if wasQuiet || buffer.readableBytes >= KittermConstants.outputBatchMaxBytes {
            flushNow()
            return
        }

        if scheduledFlush == nil {
            scheduledFlush = eventLoop.scheduleTask(
                in: .milliseconds(Int64(KittermConstants.outputBatchWindowMs))
            ) { [weak self] in
                self?.scheduledFlush = nil
                self?.flushNow()
            }
        }
    }

    func flushNow() {
        eventLoop.assertInEventLoop()
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard buffer.readableBytes > 0 else { return }
        let out = buffer
        buffer = ByteBuffer()
        onFlush(out)
    }

    func close() {
        eventLoop.assertInEventLoop()
        closed = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        buffer.clear()
    }
}
