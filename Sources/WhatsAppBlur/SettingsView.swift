import SwiftUI

private let accent = Color(red: 0.11, green: 0.67, blue: 0.38)

/// The menu bar panel, laid out like the Privacy Extension for WhatsApp Web's popup.
struct SettingsView: View {
    @AppStorage(Settings.Key.enabled) private var enabled = true
    @AppStorage(Settings.Key.noTransitionDelay) private var noTransitionDelay = false
    @AppStorage(Settings.Key.unblurOnAppHover) private var unblurOnAppHover = false
    @AppStorage(Settings.Key.blurOnIdle) private var blurOnIdle = false
    @AppStorage(Settings.Key.idleSeconds) private var idleSeconds = Settings.defaultIdleSeconds

    @State private var expanded: String?
    let status: String
    let needsAccessibility: Bool
    let openAccessibilitySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            row("Toggle", isOn: $enabled)
                .font(.system(size: 13, weight: .semibold))

            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(BlurCategory.allCases) { category in
                CategoryRow(category: category, expanded: $expanded)
                Divider().padding(.leading, 14)
            }

            row("No transition delay", isOn: $noTransitionDelay)
            Divider().padding(.leading, 14)
            row("Unblur all on app hover", isOn: $unblurOnAppHover)
            Divider().padding(.leading, 14)
            idleRow

            Divider()
            footer
        }
        .frame(width: 280)
        .toggleStyle(.switch)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("WhatsApp Blur")
                Text("Privacy for your chats")
            }
            .font(.system(size: 14, weight: .bold))
            Spacer()
        }
        .padding(14)
    }

    private var idleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Blur WhatsApp on Idle")
                Spacer()
                GearButton(isExpanded: expanded == "idle") {
                    expanded = expanded == "idle" ? nil : "idle"
                }
                Toggle("", isOn: $blurOnIdle).labelsHidden()
            }
            if expanded == "idle" {
                Picker("Idle after", selection: $idleSeconds) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(needsAccessibility ? Color.orange : accent)
                    .frame(width: 7, height: 7)
                Text(status)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌃⌥B toggles")
                    .foregroundStyle(.tertiary)
            }
            HStack {
                if needsAccessibility {
                    Button("Grant Accessibility…", action: openAccessibilitySettings)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .font(.system(size: 11))
        .padding(14)
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct CategoryRow: View {
    let category: BlurCategory
    @Binding var expanded: String?
    @AppStorage private var isOn: Bool
    @AppStorage private var radius: Double

    init(category: BlurCategory, expanded: Binding<String?>) {
        self.category = category
        _expanded = expanded
        _isOn = AppStorage(wrappedValue: category.defaultEnabled, category.enabledKey)
        _radius = AppStorage(wrappedValue: Settings.defaultRadius, category.radiusKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.title)
                Spacer()
                if category.hasStrength {
                    GearButton(isExpanded: expanded == category.id) {
                        expanded = expanded == category.id ? nil : category.id
                    }
                }
                Toggle("", isOn: $isOn).labelsHidden()
            }
            if expanded == category.id {
                HStack {
                    Text("Blur")
                        .foregroundStyle(.secondary)
                    Slider(value: $radius, in: 3...24)
                    Text("\(Int(radius))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct GearButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(Circle().strokeBorder(accent, lineWidth: 1).opacity(isExpanded ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .help("Blur settings")
    }
}
