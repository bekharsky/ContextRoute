import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPreferencesView: View {
    @ObservedObject var model: RouterModel
    @StateObject private var loginItem = LoginItemModel()
    let browsers: [BrowserInfo]
    @Binding var appearance: String
    @Binding var language: String
    let highlightedAnchor: String?
    let onEditFallback: () -> Void
    @State private var pendingImport: RouterConfiguration?
    @State private var confirmsImport = false
    @State private var transferError: String?
    @State private var transferSucceeded = false

    private var fallbackID: Binding<String> {
        Binding(get: { model.fallbackBrowserBundleIdentifier ?? "" }, set: { id in
            guard let browser = browsers.first(where: { $0.bundleIdentifier == id }) else { return }
            model.setFallbackBrowser(browser)
        })
    }

    private var fallbackOptions: [SettingsPopup.Option] {
        var options = [SettingsPopup.Option(id: "", title: ContextRouteLocalization.string("Choose browser"), isEnabled: false)]
        if let id = model.fallbackBrowserBundleIdentifier, !browsers.contains(where: { $0.bundleIdentifier == id }) {
            options.append(.init(id: id, title: ContextRouteLocalization.format("%@ (not installed)", arguments: [model.fallbackBrowserName ?? id])))
        }
        options += browsers.map { .init(id: $0.bundleIdentifier, title: $0.name) }
        return options
    }

    private var appearanceOptions: [SettingsPopup.Option] {
        [
            .init(id: AppearanceChoice.system.rawValue, title: ContextRouteLocalization.string("System")),
            .init(id: AppearanceChoice.light.rawValue, title: ContextRouteLocalization.string("Light")),
            .init(id: AppearanceChoice.dark.rawValue, title: ContextRouteLocalization.string("Dark"))
        ]
    }

    private var languageOptions: [SettingsPopup.Option] {
        [
            .init(id: InterfaceLanguage.english.rawValue, title: ContextRouteLocalization.string("English")),
            .init(id: InterfaceLanguage.russian.rawValue, title: "Русский"),
            .init(id: InterfaceLanguage.system.rawValue, title: ContextRouteLocalization.string("System language"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesLayout.sectionSpacing) {
            SettingsCard {
                VStack(alignment: .leading, spacing: PreferencesLayout.rowSpacing) {
                    settingsRow("Fallback browser") {
                        AppIconView(appURL: browsers.first { $0.bundleIdentifier == fallbackID.wrappedValue }?.appURL, symbol: "globe", size: 24)
                        SettingsPopup(options: fallbackOptions, selection: fallbackID,
                            label: ContextRouteLocalization.string("Fallback browser"), isEnabled: model.canEditSettings)
                            .frame(width: PreferencesLayout.controlWidth)
                    }
                    if browsers.first(where: { $0.bundleIdentifier == model.fallbackBrowserBundleIdentifier })
                        .map({ BrowserCatalog.supportsProfiles(for: $0) }) == true || model.fallbackProfileIdentifier != nil {
                        Divider().padding(.vertical, 4)
                        settingsRow("Profile") {
                            Button(action: onEditFallback) {
                                HStack {
                                    Text(model.fallbackProfileName ?? model.fallbackProfileIdentifier ?? ContextRouteLocalization.string("Use browser default"))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).frame(width: PreferencesLayout.controlWidth)
                            .disabled(!model.canEditSettings)
                            .help(model.fallbackProfileName ?? ContextRouteLocalization.string("Choose profile…"))
                        }
                    }
                    settingsDescription("Used for unmatched links. Website routes, Open in apps, and app routes take priority.")
                    if let issue = model.fallbackIssue {
                        Label(issue.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .searchTarget("fallback", highlighted: highlightedAnchor)

            SettingsCard {
                VStack(alignment: .leading, spacing: PreferencesLayout.rowSpacing) {
                    settingsRow("Appearance") {
                        SettingsSegmentedControl(options: appearanceOptions, selection: $appearance,
                            label: ContextRouteLocalization.string("Appearance"))
                            .frame(width: PreferencesLayout.controlWidth)
                    }
                    .searchTarget("appearance", highlighted: highlightedAnchor)
                    settingsDescription("System follows the appearance set in macOS.")
                    Divider().padding(.vertical, 4)
                    settingsRow("Language") {
                        SettingsPopup(options: languageOptions, selection: $language,
                            label: ContextRouteLocalization.string("Language"))
                            .frame(width: PreferencesLayout.controlWidth)
                    }
                    .searchTarget("language", highlighted: highlightedAnchor)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: PreferencesLayout.rowSpacing) {
                    settingsRow("Launch at login") {
                        Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                            .frame(width: PreferencesLayout.controlWidth, alignment: .trailing)
                    }
                    settingsDescription("Start in the menu bar when you sign in.")
                    if loginItem.requiresApproval {
                        Text("Allow ContextRoute in Login Items to finish enabling this setting.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Login Items", action: loginItem.openSystemSettings).buttonStyle(.bordered)
                    }
                    if let error = loginItem.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout)
                    }
                }
            }
            .searchTarget("login", highlighted: highlightedAnchor)

            SettingsCard {
                VStack(alignment: .leading, spacing: PreferencesLayout.rowSpacing) {
                    settingsRow("Import and export") {
                        HStack(spacing: PreferencesLayout.rowSpacing) {
                            Button(action: chooseImport) {
                                Text("Import…").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button(action: chooseExport) {
                                Text("Export…").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.recovery == .unreadable)
                        }
                        .frame(width: PreferencesLayout.controlWidth)
                    }
                    settingsDescription("Transfer app and website routes, app handlers, and the fallback browser and profile between Macs.")
                    if let transferError {
                        Label(transferError, systemImage: "exclamationmark.triangle.fill").font(.callout)
                    } else if transferSucceeded {
                        Text("Settings exported.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchTarget("transfer", highlighted: highlightedAnchor)
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
        .alert("Replace settings?", isPresented: $confirmsImport, presenting: pendingImport) { imported in
            Button("Cancel", role: .cancel) { pendingImport = nil }
            Button("Import", role: .destructive) {
                _ = model.importSettings(imported)
                pendingImport = nil
            }
        } message: { _ in
            if model.canEditSettings {
                Text("This replaces your app and website routes, app handlers, and fallback browser and profile. You can undo the import.")
            } else {
                Text("This replaces the unreadable settings. A copy of the original file will be kept.")
            }
        }
    }

    private func settingsRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: PreferencesLayout.rowSpacing) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: PreferencesLayout.rowHeight)
    }

    private func settingsDescription(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseImport() {
        guard let window = NSApp.keyWindow else { return }
        transferError = nil
        transferSucceeded = false
        let panel = NSOpenPanel()
        panel.title = ContextRouteLocalization.string("Import settings")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [panel] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                pendingImport = try model.readImport(at: url)
                confirmsImport = true
            } catch {
                transferError = ContextRouteLocalization.format("Couldn't import settings: %@", arguments: [error.localizedDescription])
            }
        }
    }

    private func chooseExport() {
        guard let window = NSApp.keyWindow else { return }
        transferError = nil
        transferSucceeded = false
        let panel = NSSavePanel()
        panel.title = ContextRouteLocalization.string("Export settings")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ContextRoute-settings.json"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [panel] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try model.exportSettings(to: url)
                transferSucceeded = true
            } catch {
                transferError = ContextRouteLocalization.format("Couldn't export settings: %@", arguments: [error.localizedDescription])
            }
        }
    }
}

private enum PreferencesLayout {
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let controlWidth: CGFloat = 220
}

extension View {
    func searchTarget(_ anchor: String, highlighted: String?) -> some View {
        self.id(anchor)
            .overlay {
                if highlighted == anchor {
                    RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.10))
                        .allowsHitTesting(false)
                }
            }
    }
}
