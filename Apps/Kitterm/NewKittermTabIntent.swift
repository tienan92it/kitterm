import AppIntents
import Foundation

/// Opens a new shell tab in Kitterm.
///
/// **SPM limitation:** `swift run KittermApp` produces a bare executable, not an `.app`
/// bundle. App Intents metadata extraction and Shortcuts/Siri discovery require packaging
/// KittermApp as a macOS application target in Xcode (see README → App Intents).
///
/// When that packaging is in place, this intent posts `KittermNotifications.newTab` and
/// the running app creates a tab (same as ⌘T).
struct NewKittermTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Kitterm Tab"
    static let description = IntentDescription("Open a new shell tab in Kitterm.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: KittermNotifications.newTab, object: nil)
        return .result()
    }
}

/// Registered when Kitterm is packaged as an `.app` with App Intents metadata extraction.
struct KittermAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewKittermTabIntent(),
            phrases: [
                "New \(.applicationName) tab",
                "Open a new \(.applicationName) tab",
            ],
            shortTitle: "New Tab",
            systemImageName: "plus.square.on.square"
        )
    }
}
