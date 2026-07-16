import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            sessionBody
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            store.ensureInitialSession()
        }
            .navigationTitle(windowTitle)
            .onReceive(NotificationCenter.default.publisher(for: KittermNotifications.newTab)) { _ in
                store.newTab()
            }
    }

    private var windowTitle: String {
        guard let session = store.selectedSession else { return "Kitterm" }
        return session.chromeTitle
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        TabChip(
                            title: session.tabLabel,
                            hint: session.tabAccessibilityHint,
                            selected: session.id == store.selectedID,
                            onSelect: { store.select(session.id) },
                            onClose: { store.closeTab(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Button {
                store.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .padding(.trailing, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var sessionBody: some View {
        if let session = store.selectedSession {
            ZStack(alignment: .top) {
                MetalTerminalView(session: session, settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { session.focusTerminal() }

                if let message = session.statusMessage {
                    Text(message)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.yellow.opacity(0.85))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .id(session.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Sessions")
                    .font(.headline)
                Text("Open a new tab to start a shell.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TabChip: View {
    let title: String
    let hint: String
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
            .buttonStyle(.plain)
            .help(hint)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}
