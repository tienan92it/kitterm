import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $settings.fontName) {
                    ForEach(AppSettings.availableFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 9...28, step: 1)
                    Text("\(Int(settings.fontSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Picker("Cursor", selection: $settings.cursorStyle) {
                    ForEach(CursorStyleSetting.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Section("Buffer") {
                HStack {
                    Text("Scrollback lines")
                    Spacer()
                    TextField(
                        "",
                        value: $settings.scrollback,
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                }
                Text("Applied to open tabs immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 360)
    }
}
