import AppKit
import SwiftUI

struct AppOverrideRow: View {
    let override: URLAppOverride
    let onToggle: (Bool) -> Void

    private var targetAppURL: URL? {
        BrowserCatalog.findApplication(for: override)
    }

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(appURL: targetAppURL, symbol: override.systemSymbol, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(override.name)
                        .font(.body.weight(.medium))
                    if override.isEnabled && targetAppURL == nil {
                        Text("Not installed")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    } else if !override.isEnabled {
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(override.matchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(override.matchSummary)
                if override.isEnabled && targetAppURL == nil {
                    Text("Inactive until the app is installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Toggle(override.name, isOn: Binding(get: { override.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(override.isEnabled ? LocalizedStringKey("Turn handler off") : LocalizedStringKey("Turn handler on"))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}
