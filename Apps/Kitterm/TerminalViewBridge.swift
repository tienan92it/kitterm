import AppKit
import Foundation
import SwiftTerm

/// Coordinator between SwiftTerm `TerminalView` and a `TerminalSession`.
@MainActor
final class TerminalViewBridge: NSObject, TerminalViewDelegate {
    weak var terminalView: TerminalView?
    weak var session: TerminalSession?
    private var settings: AppSettings
    private var metalEnabled = false

    init(session: TerminalSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        super.init()
        session.terminalBridge = self
    }

    func attach(to view: TerminalView) {
        terminalView = view
        view.terminalDelegate = self
        applySettings(settings)
        enableMetalIfPossible(on: view)
    }

    func applySettings(_ settings: AppSettings) {
        self.settings = settings
        guard let view = terminalView else { return }
        view.font = settings.resolvedFont
        view.nativeForegroundColor = settings.theme.foreground
        view.nativeBackgroundColor = settings.theme.background
        view.layer?.backgroundColor = settings.theme.background.cgColor
        view.caretColor = settings.theme.caret
        view.getTerminal().setCursorStyle(settings.cursorStyle.swiftTermStyle)
        view.changeScrollback(settings.scrollback)
        view.needsDisplay = true
    }

    func feedOutput(_ data: Data) {
        guard !data.isEmpty, let view = terminalView else { return }
        let bytes = [UInt8](data)
        view.feed(byteArray: bytes[...])
    }

    // MARK: - TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            session?.sendResize(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in
            session?.applyTitleFromTerminal(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor in
            session?.applyCwdFromTerminal(directory)
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let copy = Data(data)
        Task { @MainActor in
            session?.sendInput(copy)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        Task { @MainActor in
            if let string = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
    }

    func copySelection() {
        terminalView?.copy(self)
    }

    func pasteClipboard() {
        terminalView?.paste(self)
    }

    func selectAllText() {
        terminalView?.selectAll(self)
    }

    func focusTerminal() {
        guard let view = terminalView else { return }
        view.window?.makeFirstResponder(view)
    }

    private func enableMetalIfPossible(on view: TerminalView) {
        guard !metalEnabled else { return }
        // Metal requires a window; retry on next runloop if not attached yet.
        if view.window == nil {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.enableMetalIfPossible(on: view)
            }
            return
        }
        do {
            try view.setUseMetal(true)
            view.metalBufferingMode = .perFrameAggregated
            metalEnabled = true
        } catch {
            // CoreGraphics path remains available.
        }
        view.needsDisplay = true
    }
}
