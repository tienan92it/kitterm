import Foundation
import KittermProtocol

/// One tab ↔ one WebSocket ↔ one PTY shell.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date

    @Published var title: String
    @Published var cwd: String
    @Published var shellName: String
    @Published var connectionState: DaemonWebSocket.State = .idle
    @Published var exitCode: Int32?
    @Published var statusMessage: String?

    /// Weak bridge into the live `TerminalView` for feeding output / applying settings.
    weak var terminalBridge: TerminalViewBridge?

    private let socket = DaemonWebSocket()
    private var lastCols: UInt16 = KittermConstants.defaultCols
    private var lastRows: UInt16 = KittermConstants.defaultRows
    private var didSendInitialResize = false

    /// Tab chrome: OSC title when set; else cwd basename; else shell name.
    var tabLabel: String {
        let folder = cwdDirectoryName
        if !title.isEmpty, title != shellName {
            return title
        }
        if let folder {
            return folder
        }
        if !title.isEmpty {
            return title
        }
        return shellName.isEmpty ? "Shell" : shellName
    }

    /// Window / dock-style title: `label — cwd` when cwd known.
    var chromeTitle: String {
        let label = tabLabel
        guard !cwd.isEmpty else { return label }
        if label == cwdDirectoryName {
            return "\(label) · \(shellDisplayName)"
        }
        return "\(label) — \(cwd)"
    }

    /// Tooltip / accessibility: full cwd when available, else shell.
    var tabAccessibilityHint: String {
        if !cwd.isEmpty { return cwd }
        return shellDisplayName
    }

    var cwdDirectoryName: String? {
        guard !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private var shellDisplayName: String {
        shellName.isEmpty ? "shell" : shellName
    }

    init(id: UUID = UUID()) {
        self.id = id
        self.createdAt = Date()
        self.title = ""
        self.cwd = ""
        self.shellName = "shell"
        socket.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }
        socket.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handleFrame(frame)
            }
        }
    }

    func connect() {
        let port = DaemonPort.current()
        statusMessage = "Connecting to 127.0.0.1:\(port)…"
        exitCode = nil
        didSendInitialResize = false
        socket.connect(port: port)
    }

    func disconnect() {
        socket.close()
        terminalBridge = nil
    }

    func sendInput(_ data: Data) {
        guard connectionState == .connected, !data.isEmpty else { return }
        // Daemon rejects frames above maxInputBytes; chunk large pastes.
        let maxChunk = KittermConstants.maxInputBytes
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxChunk, data.count)
            socket.send(.input(data.subdata(in: offset..<end)))
            offset = end
        }
    }

    func sendInput(_ data: ArraySlice<UInt8>) {
        sendInput(Data(data))
    }

    func copySelection() {
        terminalBridge?.copySelection()
    }

    func pasteClipboard() {
        terminalBridge?.pasteClipboard()
    }

    func selectAllText() {
        terminalBridge?.selectAllText()
    }

    func focusTerminal() {
        terminalBridge?.focusTerminal()
    }

    func sendResize(cols: Int, rows: Int) {
        let c = UInt16(clamping: max(1, min(Int(KittermConstants.maxCols), cols)))
        let r = UInt16(clamping: max(1, min(Int(KittermConstants.maxRows), rows)))
        lastCols = c
        lastRows = r
        guard connectionState == .connected else { return }
        socket.send(.resize(cols: c, rows: r))
        didSendInitialResize = true
    }

    func applyTitleFromTerminal(_ title: String) {
        // Prefer daemon out-of-band title when present; still accept OSC titles from the stream.
        if !title.isEmpty {
            self.title = title
        }
    }

    func applyCwdFromTerminal(_ directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        if let url = URL(string: directory), url.scheme == "file" {
            cwd = url.path
        } else {
            cwd = directory
        }
    }

    private func handleState(_ state: DaemonWebSocket.State) {
        connectionState = state
        switch state {
        case .connecting:
            statusMessage = "Connecting…"
        case .connected:
            statusMessage = nil
            if !didSendInitialResize {
                socket.send(.resize(cols: lastCols, rows: lastRows))
                didSendInitialResize = true
            }
        case .failed(let reason):
            statusMessage = reason
        case .closed:
            if exitCode == nil {
                statusMessage = "Disconnected"
            }
        case .idle:
            break
        }
    }

    private func handleFrame(_ frame: ServerFrame) {
        switch frame {
        case .output(let data):
            terminalBridge?.feedOutput(data)
        case .title(let value):
            title = value
        case .cwd(let value):
            cwd = value
        case .sessionMeta(let meta):
            shellName = URL(fileURLWithPath: meta.shell).lastPathComponent
            if !meta.cwd.isEmpty {
                cwd = meta.cwd
            }
            // Leave `title` empty so tab chrome can prefer cwd basename over shell.
        case .exit(let code):
            exitCode = code
            statusMessage = "Shell exited (\(code))"
        }
    }
}
