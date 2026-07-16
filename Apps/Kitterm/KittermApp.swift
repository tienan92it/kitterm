import SwiftUI

@main
struct KittermApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("Kitterm") {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    store.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    store.closeSelectedTab()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    store.copySelection()
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    store.pasteClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Select All") {
                    store.selectAllText()
                }
                .keyboardShortcut("a", modifiers: .command)
            }
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}
