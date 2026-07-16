import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI host for SwiftTerm's AppKit `TerminalView` with Metal rendering preferred.
struct MetalTerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var settings: AppSettings

    @MainActor
    func makeCoordinator() -> TerminalViewBridge {
        TerminalViewBridge(session: session, settings: settings)
    }

    @MainActor
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        context.coordinator.attach(to: view)
        DispatchQueue.main.async {
            context.coordinator.focusTerminal()
        }
        return view
    }

    @MainActor
    func updateNSView(_ view: TerminalView, context: Context) {
        if context.coordinator.session !== session {
            context.coordinator.session = session
            session.terminalBridge = context.coordinator
            DispatchQueue.main.async {
                context.coordinator.focusTerminal()
            }
        }
        context.coordinator.applySettings(settings)
    }

    @MainActor
    static func dismantleNSView(_ nsView: TerminalView, coordinator: TerminalViewBridge) {
        coordinator.terminalView = nil
        if coordinator.session?.terminalBridge === coordinator {
            coordinator.session?.terminalBridge = nil
        }
    }
}
