import Combine
import Foundation
import SwiftUI

/// Owns the tab list. New tab → new WS; close tab → close WS (daemon kills PTY).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?

    private var cancellables: [UUID: AnyCancellable] = [:]

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func ensureInitialSession() {
        guard sessions.isEmpty else { return }
        newTab()
    }

    @discardableResult
    func newTab() -> TerminalSession {
        let session = TerminalSession()
        bind(session)
        sessions.append(session)
        selectedID = session.id
        session.connect()
        return session
    }

    func closeTab(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        session.disconnect()
        cancellables[id] = nil
        sessions.remove(at: index)

        if sessions.isEmpty {
            selectedID = nil
            newTab()
            return
        }

        if selectedID == id {
            let next = sessions[min(index, sessions.count - 1)]
            selectedID = next.id
        }
    }

    func closeSelectedTab() {
        guard let selectedID else { return }
        closeTab(selectedID)
    }

    func select(_ id: TerminalSession.ID) {
        selectedID = id
        sessions.first { $0.id == id }?.focusTerminal()
    }

    func copySelection() {
        selectedSession?.copySelection()
    }

    func pasteClipboard() {
        selectedSession?.pasteClipboard()
    }

    func selectAllText() {
        selectedSession?.selectAllText()
    }

    private func bind(_ session: TerminalSession) {
        cancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
