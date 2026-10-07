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
        let initialBrowserIdentifier = route?.browserBundleIdentifier ?? browser?.bundleIdentifier ?? ""
        _sourceBundleIdentifier = State(initialValue: route?.sourceBundleIdentifier ?? "")
        _sourceName = State(initialValue: route?.sourceName ?? "")
        _browserBundleIdentifier = State(initialValue: initialBrowserIdentifier)
        _userDataDirectory = State(initialValue: route?.userDataDirectory ?? browser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? "")
        _profileIdentifier = State(initialValue: route?.profileIdentifier ?? "")
        _isScanning = State(initialValue: browsers.first { $0.bundleIdentifier == initialBrowserIdentifier }
            .map { BrowserCatalog.supportsProfiles(for: $0) } ?? false)
    }

    private var selectedBrowser: BrowserInfo? { browsers.first { $0.bundleIdentifier == browserBundleIdentifier } }
    private var profiles: [BrowserProfile] { profileScan?.profiles ?? [] }
    private var profileSelectionIsValid: Bool { profileIdentifier.isEmpty || profiles.contains { $0.id == profileIdentifier } }
    private var replacement: SourceRoute? {
        model.sourceRoutes.first { $0.sourceBundleIdentifier == sourceBundleIdentifier && $0.id != route?.id }
    }
    private var scanID: String { "\(browserBundleIdentifier)|\(userDataDirectory)|\(scanGeneration)" }
    private var usesDefaultProfileFolder: Bool {
        guard let browser = selectedBrowser, let defaultFolder = BrowserCatalog.defaultUserDataDirectory(for: browser) else { return true }
        return userDataDirectory.isEmpty || BrowserCatalog.expandHome(userDataDirectory) == defaultFolder
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    sourceAppCard
                    browserCard
                    if !sourceBundleIdentifier.isEmpty || selectedBrowser.map({ BrowserCatalog.supportsProfiles(for: $0) }) == true {
                        advancedCard
                    }
                    if let replacement {
                        Label(ContextRouteLocalization.format("Saving replaces the existing route for %@. You can undo this change.", arguments: [replacement.sourceName]),
                            systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.storageError {
                        Label(error.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            Divider()
            footer
        }
        .frame(width: 580, height: 420)
        .controlSize(.regular)
        .onChange(of: browserBundleIdentifier) { _, _ in
            profileIdentifier = ""
            profileScan = nil
            userDataDirectory = selectedBrowser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? ""
            isScanning = selectedBrowser.map { BrowserCatalog.supportsProfiles(for: $0) } ?? false
        }
        .task(id: scanID) { await refreshProfiles() }
        .alert("Replace app route?", isPresented: $confirmsReplacement) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive, action: save)
        } message: { Text("The existing route for this source app will be replaced. You can undo the change.") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route == nil ? LocalizedStringKey("New app route") : LocalizedStringKey("Edit app route"))
                .font(.title2.weight(.semibold))
            SectionIntro("Choose a source app, browser, and optional profile.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var sourceAppCard: some View {
        SettingsCard {
            formRow("Source app") {
                HStack(spacing: 8) {
                    AppIconView(appURL: BrowserCatalog.applicationURL(bundleIdentifier: sourceBundleIdentifier), symbol: "app.fill", size: 32)
                    Text(sourceName.isEmpty ? ContextRouteLocalization.string("Choose an app") : sourceName)
                        .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Choose app…", action: chooseSourceApplication).buttonStyle(.bordered).fixedSize()
                }
            }
        }
    }

    private var browserCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                formRow("Browser") {
                    HStack(spacing: 8) {
                        AppIconView(appURL: selectedBrowser?.appURL, symbol: "globe", size: 32)
                        Picker("Browser", selection: $browserBundleIdentifier) {
                            if selectedBrowser == nil, !browserBundleIdentifier.isEmpty {
                                Text(ContextRouteLocalization.format("%@ (not installed)", arguments: [route?.browserName ?? browserBundleIdentifier]))
                                    .tag(browserBundleIdentifier)
                            }
                            ForEach(browsers) { browser in Text(browser.name).tag(browser.bundleIdentifier) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Color.clear.frame(width: 24, height: 24).accessibilityHidden(true)
                    }
                }
                if let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) {
                    Divider()
                    formRow("Profile") {
                        HStack(spacing: 8) {
                            Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                            profilePicker
                            profileActivity
                        }
                    }
                    profileFeedback
                } else if selectedBrowser == nil {
                    Label("Choose an installed browser to save this route.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Profile selection isn't available for this browser. Links will open the browser normally.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $profileIdentifier) {
            Text("Use browser default").tag("")
            if !profileIdentifier.isEmpty, !profileSelectionIsValid {
                let name = route?.profileIdentifier == profileIdentifier ? (route?.profileName ?? profileIdentifier) : profileIdentifier
                Text(isScanning || profileScan == nil ? name : ContextRouteLocalization.format("%@ (unavailable)", arguments: [name]))
                    .tag(profileIdentifier)
            }
            ForEach(profiles) { profile in Text(profile.name).tag(profile.id) }
        }
        .labelsHidden().frame(maxWidth: .infinity)
        .disabled(isScanning)
    }

    private var profileActivity: some View {
        // Reserve the same space for both states so scanning never moves the fields.
        ZStack {
            Button { scanGeneration += 1 } label: {
                Label("Refresh profile list", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help("Refresh profile list")
            .disabled(isScanning).opacity(isScanning ? 0 : 1)
            .accessibilityHidden(isScanning)
            if isScanning {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading profiles…")
                    .help("Loading profiles…")
            }
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var profileFeedback: some View {
        if let failure = profileScan?.failureMessage {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Profile folder…", action: chooseUserDataDirectory).buttonStyle(.link)
            }
        } else if profileScan != nil, !profileSelectionIsValid, !isScanning {
            Text("This profile wasn't found in the selected folder. Choose it again or change the folder.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedCard: some View {
        SettingsCard {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if !sourceBundleIdentifier.isEmpty {
                        formRow("App identifier", alignment: .top) {
                            Text(sourceBundleIdentifier).font(.caption.monospaced())
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) {
                        if !sourceBundleIdentifier.isEmpty { Divider() }
                        formRow("Profile folder", alignment: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(userDataDirectory).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("Profile folder…", action: chooseUserDataDirectory).buttonStyle(.bordered)
                                    Button("Use default folder") {
                                        userDataDirectory = BrowserCatalog.defaultUserDataDirectory(for: browser) ?? ""
                                        profileIdentifier = ""
                                        scanGeneration += 1
                                    }
                                    .buttonStyle(.bordered).disabled(usesDefaultProfileFolder)
                                }
                                .controlSize(.small)
                                Text(ContextRouteLocalization.format("Choose the folder containing %@, not an individual profile folder.",
                                    arguments: [BrowserCatalog.metadataFileName(for: browser) ?? "profiles"]))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formRow<Content: View>(_ title: LocalizedStringKey, alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title).frame(width: 96, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            Button(replacement == nil ? LocalizedStringKey("Save route") : LocalizedStringKey("Replace route")) {
                if replacement != nil { confirmsReplacement = true } else { save() }
            }
            .primaryActionStyle().keyboardShortcut(.defaultAction)
            .disabled(sourceBundleIdentifier.isEmpty || selectedBrowser == nil || !profileSelectionIsValid || isScanning || !model.canEditSettings)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
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
