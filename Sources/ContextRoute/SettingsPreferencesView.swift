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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                HStack(spacing: 10) {
                    Text("Fallback browser")
                    Spacer(minLength: 12)
                    AppIconView(appURL: browsers.first { $0.bundleIdentifier == fallbackID.wrappedValue }?.appURL, symbol: "globe", size: 24)
                    Picker("Fallback browser", selection: fallbackID) {
                        Text("Choose browser").tag("").disabled(true)
                        if let id = model.fallbackBrowserBundleIdentifier, !browsers.contains(where: { $0.bundleIdentifier == id }) {
                            Text(ContextRouteLocalization.format("%@ (not installed)", arguments: [model.fallbackBrowserName ?? id])).tag(id)
                        }
                        ForEach(browsers) { browser in Text(browser.name).tag(browser.bundleIdentifier) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                .disabled(!model.canEditSettings)
            }
            .searchTarget("fallback", highlighted: highlightedAnchor)
            SectionIntro("Used for links without a matching app route. Open in apps and app routes take priority.")

            SettingsCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 12) {
                        Text("Appearance")
                        Spacer(minLength: 12)
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag(AppearanceChoice.system.rawValue)
                            Text("Light").tag(AppearanceChoice.light.rawValue)
                            Text("Dark").tag(AppearanceChoice.dark.rawValue)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    }
                    .searchTarget("appearance", highlighted: highlightedAnchor)
                    Text("System follows the appearance set in macOS.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: 12) {
                        Text("Language")
                        Spacer(minLength: 12)
                        Picker("Language", selection: $language) {
                            Text("English").tag(InterfaceLanguage.english.rawValue)
                            Text("Русский").tag(InterfaceLanguage.russian.rawValue)
                            Text("System language").tag(InterfaceLanguage.system.rawValue)
                        }.labelsHidden().pickerStyle(.menu).frame(width: 190, alignment: .trailing)
                    }
                    .searchTarget("language", highlighted: highlightedAnchor)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Launch at login")
                        Spacer(minLength: 12)
                        Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.regular)
                    }
                    Text("Start in the menu bar when you sign in.").font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Import and export")
                        Spacer()
                        Button("Import…", action: chooseImport).buttonStyle(.bordered)
                        Button("Export…", action: chooseExport).buttonStyle(.bordered)
                            .disabled(model.recovery == .unreadable)
                    }
                    Text("Transfer app routes, app handlers and the fallback browser between Macs.")
                        .font(.caption).foregroundStyle(.secondary)
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
                Text("This replaces your app routes, app handlers and fallback browser. You can undo the import.")
            } else {
                Text("This replaces the unreadable settings. A copy of the original file will be kept.")
            }
        }
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
