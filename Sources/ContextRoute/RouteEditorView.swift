import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RouteEditorView: View {
    @ObservedObject var model: RouterModel
    let browsers: [BrowserInfo]
    let route: SourceRoute?
    @Environment(\.dismiss) private var dismiss
    @State private var sourceBundleIdentifier: String
    @State private var sourceName: String
    @State private var browserBundleIdentifier: String
    @State private var userDataDirectory: String
    @State private var profileIdentifier: String
    @State private var profileScan: ProfileScanResult?
    @State private var showsAdvanced = false
    @State private var scanGeneration = 0
    @State private var isScanning = false
    @State private var confirmsReplacement = false

    init(model: RouterModel, browsers: [BrowserInfo], route: SourceRoute?) {
        self.model = model
        self.browsers = browsers
        self.route = route
        let preferred = route?.browserBundleIdentifier ?? model.fallbackBrowserBundleIdentifier
        let browser = browsers.first { $0.bundleIdentifier == preferred } ?? browsers.first
        _sourceBundleIdentifier = State(initialValue: route?.sourceBundleIdentifier ?? "")
        _sourceName = State(initialValue: route?.sourceName ?? "")
        _browserBundleIdentifier = State(initialValue: route?.browserBundleIdentifier ?? browser?.bundleIdentifier ?? "")
        _userDataDirectory = State(initialValue: route?.userDataDirectory ?? browser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? "")
        _profileIdentifier = State(initialValue: route?.profileIdentifier ?? "")
    }

    private var selectedBrowser: BrowserInfo? { browsers.first { $0.bundleIdentifier == browserBundleIdentifier } }
    private var profiles: [BrowserProfile] { profileScan?.profiles ?? [] }
    private var profileSelectionIsValid: Bool { profileIdentifier.isEmpty || profiles.contains { $0.id == profileIdentifier } }
    private var replacement: SourceRoute? {
        model.sourceRoutes.first { $0.sourceBundleIdentifier == sourceBundleIdentifier && $0.id != route?.id }
    }
    private var scanID: String { "\(browserBundleIdentifier)|\(userDataDirectory)|\(scanGeneration)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(route == nil ? LocalizedStringKey("New app route") : LocalizedStringKey("Edit app route"))
                    .font(.title2.weight(.semibold))
                SectionIntro("Choose a source app, browser, and optional profile.")
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source app").font(.headline)
                    HStack(spacing: 11) {
                        AppIconView(appURL: BrowserCatalog.applicationURL(bundleIdentifier: sourceBundleIdentifier), symbol: "app.fill", size: 32)
                        Text(sourceName.isEmpty ? ContextRouteLocalization.string("Choose an app") : sourceName)
                            .font(.body.weight(.medium))
                        Spacer()
                        Button("Choose app…", action: chooseSourceApplication).buttonStyle(.bordered)
                    }
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("Browser")
                        Spacer()
                        AppIconView(appURL: selectedBrowser?.appURL, symbol: "globe", size: 30)
                        Picker("Browser", selection: $browserBundleIdentifier) {
                            if selectedBrowser == nil, !browserBundleIdentifier.isEmpty {
                                Text(ContextRouteLocalization.format("%@ (not installed)", arguments: [route?.browserName ?? browserBundleIdentifier]))
                                    .tag(browserBundleIdentifier)
                            }
                            ForEach(browsers) { browser in Text(browser.name).tag(browser.bundleIdentifier) }
                        }.labelsHidden().frame(width: 240)
                    }
                    if let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) {
                        Divider()
                        Picker("Profile", selection: $profileIdentifier) {
                            Text("Use browser default").tag("")
                            if !profileIdentifier.isEmpty, !profileSelectionIsValid {
                                Text(ContextRouteLocalization.format("%@ (unavailable)", arguments: [route?.profileName ?? profileIdentifier]))
                                    .tag(profileIdentifier)
                            }
                            ForEach(profiles) { profile in Text(profile.name).tag(profile.id) }
                        }
                        if isScanning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading profiles…").font(.caption).foregroundStyle(.secondary) }
                        } else if let failure = profileScan?.failureMessage {
                            Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Profile folder…", action: chooseUserDataDirectory).buttonStyle(.bordered)
                                Button("Try again") { scanGeneration += 1 }.buttonStyle(.bordered)
                            }
                        }
                        if !profileSelectionIsValid && !isScanning {
                            Text("This profile wasn't found in the selected folder. Choose it again or change the folder.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if selectedBrowser == nil {
                        Label("Choose an installed browser to save this route.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Profile selection isn't available for this browser. Links will open the browser normally.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if !sourceBundleIdentifier.isEmpty {
                        Text(sourceBundleIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) {
                        Text(userDataDirectory).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        HStack {
                            Button("Profile folder…", action: chooseUserDataDirectory).buttonStyle(.bordered)
                            Button("Reset") {
                                userDataDirectory = BrowserCatalog.defaultUserDataDirectory(for: browser) ?? ""
                                profileIdentifier = ""
                                scanGeneration += 1
                            }.buttonStyle(.bordered)
                            Button("Refresh profile list") { scanGeneration += 1 }.buttonStyle(.bordered)
                        }
                    }
                }.padding(.top, 8)
            }
            if let replacement {
                Label(ContextRouteLocalization.format("Saving replaces the existing route for %@. You can undo this change.", arguments: [replacement.sourceName]),
                    systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.storageError {
                Label(error.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replacement == nil ? LocalizedStringKey("Save route") : LocalizedStringKey("Replace route")) {
                    if replacement != nil { confirmsReplacement = true } else { save() }
                }
                .primaryActionStyle().keyboardShortcut(.defaultAction)
                .disabled(sourceBundleIdentifier.isEmpty || selectedBrowser == nil || !profileSelectionIsValid || isScanning || !model.canEditSettings)
            }
        }
        .padding(20).frame(width: 580).fixedSize(horizontal: false, vertical: true)
        .onChange(of: browserBundleIdentifier) { _, _ in
            profileIdentifier = ""
            profileScan = nil
            userDataDirectory = selectedBrowser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? ""
        }
        .task(id: scanID) { await refreshProfiles() }
        .alert("Replace app route?", isPresented: $confirmsReplacement) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive, action: save)
        } message: { Text("The existing route for this source app will be replaced. You can undo the change.") }
    }

    private func chooseSourceApplication() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = ContextRouteLocalization.string("Choose the source app")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [panel] response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            sourceBundleIdentifier = id
            sourceName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
    }

    private func chooseUserDataDirectory() {
        guard let window = NSApp.keyWindow, let browser = selectedBrowser else { return }
        let panel = NSOpenPanel()
        panel.title = ContextRouteLocalization.format("Choose the folder containing %@", arguments: [BrowserCatalog.metadataFileName(for: browser) ?? "profiles"])
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        let preferred = userDataDirectory.isEmpty ? BrowserCatalog.defaultUserDataDirectory(for: browser) : BrowserCatalog.expandHome(userDataDirectory)
        if let preferred {
            var directory = URL(fileURLWithPath: preferred, isDirectory: true).standardizedFileURL
            while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
            panel.directoryURL = directory
        }
        panel.beginSheetModal(for: window) { [panel] response in
            guard response == .OK, let url = panel.url else { return }
            userDataDirectory = url.path
            profileIdentifier = ""
            scanGeneration += 1
        }
    }

    private func refreshProfiles() async {
        guard let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) else {
            profileScan = nil
            isScanning = false
            return
        }
        isScanning = true
        let path = userDataDirectory.isEmpty ? nil : userDataDirectory
        let result = await Task.detached(priority: .userInitiated) { BrowserCatalog.profileScan(for: browser, userDataDirectory: path) }.value
        guard !Task.isCancelled else { return }
        profileScan = result
        isScanning = false
    }

    private func save() {
        guard let browser = selectedBrowser, profileSelectionIsValid else { return }
        let profile = profiles.first { $0.id == profileIdentifier }
        var updated = route ?? SourceRoute(sourceBundleIdentifier: sourceBundleIdentifier, sourceName: sourceName,
            browserBundleIdentifier: browser.bundleIdentifier, browserName: browser.name,
            profileIdentifier: nil, profileName: nil, userDataDirectory: nil)
        updated.sourceBundleIdentifier = sourceBundleIdentifier
        updated.sourceName = sourceName.isEmpty ? sourceBundleIdentifier : sourceName
        updated.browserBundleIdentifier = browser.bundleIdentifier
        updated.browserName = browser.name
        updated.profileIdentifier = profile?.id
        updated.profileName = profile?.name
        updated.userDataDirectory = BrowserCatalog.supportsProfiles(for: browser) ? userDataDirectory : nil
        if model.add(updated) { dismiss() }
    }
}
