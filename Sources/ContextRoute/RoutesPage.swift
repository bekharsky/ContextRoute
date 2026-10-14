import AppKit
import SwiftUI

struct RouteRow: View {
    let route: SourceRoute
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let issue: LocalizedMessage?

    private var sourceURL: URL? {
        BrowserCatalog.applicationURL(bundleIdentifier: route.sourceBundleIdentifier)
    }

    private var browserURL: URL? {
        BrowserCatalog.applicationURL(bundleIdentifier: route.browserBundleIdentifier)
    }

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(appURL: sourceURL, symbol: "app.fill", size: 32)
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            AppIconView(appURL: browserURL, symbol: "globe", size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(route.sourceName)
                        .font(.body.weight(.semibold))
                    if !route.isEnabled {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(route.browserName)
                    Text("·")
                    if let profileName = route.profileName {
                        Text(profileName)
                    } else {
                        Text("Default profile")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(route.profileName.map { "\(route.browserName) · \($0)" } ?? route.browserName)
                if let issue {
                    Label(issue.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 1)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                RouteActionButton(symbol: "pencil", title: "Edit route", action: onEdit)
                RouteActionButton(symbol: "trash", title: "Delete route", isDestructive: true, action: onDelete)
            }
            Toggle("Enable app route", isOn: Binding(get: { route.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(route.isEnabled ? LocalizedStringKey("Turn route off") : LocalizedStringKey("Turn route on"))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .contextMenu {
            Button("Edit route", action: onEdit)
            Button(route.isEnabled ? LocalizedStringKey("Turn route off") : LocalizedStringKey("Turn route on")) { onToggle(!route.isEnabled) }
            Divider()
            Button("Delete route", role: .destructive, action: onDelete)
        }
    }
}

struct WebsiteRouteRow: View {
    let route: WebsiteRoute
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let issue: LocalizedMessage?

    private var matchTitle: String {
        ContextRouteLocalization.string(route.pattern.kind == .domain && route.pattern.includesSubdomains
            ? "Domain and subdomains" : route.pattern.kind.titleKey)
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "globe").font(.system(size: 25)).foregroundStyle(.tint).frame(width: 32, height: 32)
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            AppIconView(appURL: BrowserCatalog.applicationURL(bundleIdentifier: route.target.browserBundleIdentifier), symbol: "globe", size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(route.pattern.value).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if !route.isEnabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(matchTitle) · \(route.target.displayName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("\(route.pattern.value) → \(route.target.displayName)")
                if let issue {
                    Label(issue.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                RouteActionButton(symbol: "pencil", title: "Edit route", action: onEdit)
                RouteActionButton(symbol: "trash", title: "Delete route", isDestructive: true, action: onDelete)
            }
            Toggle("Enable website route", isOn: Binding(get: { route.isEnabled }, set: onToggle))
                .labelsHidden().toggleStyle(.switch)
                .help(route.isEnabled ? LocalizedStringKey("Turn route off") : LocalizedStringKey("Turn route on"))
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RouteActionButton: View {
    let symbol: String
    let title: LocalizedStringKey
    var isDestructive = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if isDestructive {
            Button(role: .destructive, action: action, label: buttonLabel)
                .routeActionAppearance(title: title)
        } else {
            Button(action: action, label: buttonLabel)
                .routeActionAppearance(title: title)
        }
    }

    private func buttonLabel() -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 16, height: 16)
    }
}

private extension View {
    func routeActionAppearance(title: LocalizedStringKey) -> some View {
        buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(width: 34, height: 30)
            .help(title)
            .accessibilityLabel(title)
    }
}
