import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RouteEditorContext {
    case app(SourceRoute?)
    case website(WebsiteRoute?)
    case fallback
}

struct RouteEditorView: View {
    @ObservedObject var model: RouterModel
    let browsers: [BrowserInfo]
    let route: SourceRoute?
    let context: RouteEditorContext
    private let storedTarget: BrowserTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var sourceBundleIdentifier: String
    @State private var sourceName: String
    @State private var browserBundleIdentifier: String
    @State private var userDataDirectory: String
    @State private var profileIdentifier: String
    @State private var profileScan: ProfileScanResult?
    @State private var scanGeneration = 0
    @State private var isScanning = false
    @State private var confirmsReplacement = false
    @State private var websitePattern: WebsitePattern

    init(model: RouterModel, browsers: [BrowserInfo], route: SourceRoute?) {
        self.init(model: model, browsers: browsers, context: .app(route))
    }

    init(model: RouterModel, browsers: [BrowserInfo], context: RouteEditorContext) {
        self.model = model
        self.browsers = browsers
        self.context = context
        let route: SourceRoute?
        let target: BrowserTarget?
        let pattern: WebsitePattern
        switch context {
        case let .app(existing):
            route = existing
            target = existing?.target
            pattern = WebsitePattern()
        case let .website(existing):
            route = nil
            target = existing?.target
            pattern = existing?.pattern ?? WebsitePattern()
        case .fallback:
            route = nil
            target = model.configuration.fallbackTarget
            pattern = WebsitePattern()
        }
        self.route = route
        self.storedTarget = target
        _websitePattern = State(initialValue: pattern)
        let preferred = target?.browserBundleIdentifier ?? model.fallbackBrowserBundleIdentifier
        let browser = browsers.first { $0.bundleIdentifier == preferred } ?? browsers.first
        let initialBrowserIdentifier = target?.browserBundleIdentifier ?? browser?.bundleIdentifier ?? ""
        _sourceBundleIdentifier = State(initialValue: route?.sourceBundleIdentifier ?? "")
        _sourceName = State(initialValue: route?.sourceName ?? "")
        _browserBundleIdentifier = State(initialValue: initialBrowserIdentifier)
        _userDataDirectory = State(initialValue: target?.userDataDirectory ?? browser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? "")
        _profileIdentifier = State(initialValue: target?.profileIdentifier ?? "")
        _isScanning = State(initialValue: browsers.first { $0.bundleIdentifier == initialBrowserIdentifier }
            .map { BrowserCatalog.supportsProfiles(for: $0) } ?? false)
    }

    private var selectedBrowser: BrowserInfo? { browsers.first { $0.bundleIdentifier == browserBundleIdentifier } }
    private var isWebsite: Bool { if case .website = context { return true }; return false }
    private var isFallback: Bool { if case .fallback = context { return true }; return false }
    private var websiteRoute: WebsiteRoute? { if case let .website(route) = context { return route }; return nil }
    private var profiles: [BrowserProfile] { profileScan?.profiles ?? [] }
    private var profileSelectionIsValid: Bool { profileIdentifier.isEmpty || profiles.contains { $0.id == profileIdentifier } }
    private var replacement: SourceRoute? {
        guard !isWebsite, !isFallback else { return nil }
        return model.sourceRoutes.first { $0.sourceBundleIdentifier == sourceBundleIdentifier && $0.id != route?.id }
    }
    private var websiteReplacement: WebsiteRoute? {
        guard isWebsite, let pattern = websitePattern.normalized else { return nil }
        return model.websiteRoutes.first { $0.pattern.normalized == pattern && $0.id != websiteRoute?.id }
    }
    private var hasReplacement: Bool { replacement != nil || websiteReplacement != nil }
    private var inputIsValid: Bool {
        isFallback || (isWebsite ? websitePattern.normalized != nil : !sourceBundleIdentifier.isEmpty)
    }
    private var scanID: String { "\(browserBundleIdentifier)|\(userDataDirectory)|\(scanGeneration)" }
    private var usesDefaultProfileFolder: Bool {
        guard let browser = selectedBrowser, let defaultFolder = BrowserCatalog.defaultUserDataDirectory(for: browser) else { return true }
        return userDataDirectory.isEmpty || BrowserCatalog.expandHome(userDataDirectory) == defaultFolder
    }
    private var profileFolderPath: String {
        userDataDirectory.isEmpty
            ? selectedBrowser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? ""
            : BrowserCatalog.expandHome(userDataDirectory)
    }
    private var browserOptions: [SettingsPopup.Option] {
        var options = browsers.map { SettingsPopup.Option(id: $0.bundleIdentifier, title: $0.name) }
        if selectedBrowser == nil, !browserBundleIdentifier.isEmpty {
            options.insert(.init(id: browserBundleIdentifier,
                title: ContextRouteLocalization.format("%@ (not installed)", arguments: [storedTarget?.browserName ?? browserBundleIdentifier])), at: 0)
        }
        if options.isEmpty {
            options.append(.init(id: "", title: ContextRouteLocalization.string("Choose browser")))
        }
        return options
    }
    private var profileOptions: [SettingsPopup.Option] {
        var options = [SettingsPopup.Option(id: "", title: ContextRouteLocalization.string("Use browser default"))]
        if !profileIdentifier.isEmpty, !profileSelectionIsValid {
            let name = storedTarget?.profileIdentifier == profileIdentifier ? (storedTarget?.profileName ?? profileIdentifier) : profileIdentifier
            options.append(.init(id: profileIdentifier,
                title: isScanning || profileScan == nil ? name : ContextRouteLocalization.format("%@ (unavailable)", arguments: [name])))
        }
        options += profiles.map { SettingsPopup.Option(id: $0.id, title: $0.name) }
        return options
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: RouteEditorLayout.sectionSpacing) {
                    if isWebsite { websiteMatchCard }
                    else if !isFallback { sourceAppCard }
                    browserCard
                    if let replacement {
                        Label(ContextRouteLocalization.format("Saving replaces the existing route for %@. You can undo this change.", arguments: [replacement.sourceName]),
                            systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let websiteReplacement {
                        Label(ContextRouteLocalization.format("Saving replaces the existing website rule for %@. You can undo this change.",
                            arguments: [websiteReplacement.pattern.value]), systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.storageError {
                        Label(error.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, RouteEditorLayout.windowInset)
                .padding(.bottom, RouteEditorLayout.sectionSpacing)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            Divider()
            footer
        }
        .frame(width: 580, height: isWebsite ? (websitePattern.kind == .domain ? 432 : 456) : isFallback ? 350 : 420)
        .controlSize(.regular)
        .onChange(of: browserBundleIdentifier) { _, _ in
            profileIdentifier = ""
            profileScan = nil
            userDataDirectory = selectedBrowser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) } ?? ""
            isScanning = selectedBrowser.map { BrowserCatalog.supportsProfiles(for: $0) } ?? false
        }
        .task(id: scanID) { await refreshProfiles() }
        .alert(isWebsite ? LocalizedStringKey("Replace website route?") : LocalizedStringKey("Replace app route?"), isPresented: $confirmsReplacement) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive, action: save)
        } message: {
            Text(isWebsite ? LocalizedStringKey("The existing route for this address will be replaced. You can undo the change.")
                : LocalizedStringKey("The existing route for this source app will be replaced. You can undo the change."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isFallback ? LocalizedStringKey("Fallback browser")
                : isWebsite ? (websiteRoute == nil ? LocalizedStringKey("New website route") : LocalizedStringKey("Edit website route"))
                : (route == nil ? LocalizedStringKey("New app route") : LocalizedStringKey("Edit app route")))
                .font(.title2.weight(.semibold))
            SectionIntro(isFallback ? "Choose a browser and an optional profile for unmatched links."
                : isWebsite ? "Choose a domain or address, browser, and optional profile."
                : "Choose a source app, browser, and optional profile.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RouteEditorLayout.windowInset)
        .padding(.top, RouteEditorLayout.windowInset)
        .padding(.bottom, RouteEditorLayout.sectionSpacing)
    }

    private var websiteMatchCard: some View {
        SettingsCard(inset: RouteEditorLayout.cardInset) {
            VStack(alignment: .leading, spacing: RouteEditorLayout.sectionSpacing) {
                formRow("Match") {
                    HStack(spacing: RouteEditorLayout.controlSpacing) {
                        SettingsPopup(options: WebsiteMatchKind.allCases.map {
                            .init(id: $0.rawValue, title: ContextRouteLocalization.string($0.titleKey))
                        }, selection: Binding(get: { websitePattern.kind.rawValue }, set: { value in
                            if let kind = WebsiteMatchKind(rawValue: value) { websitePattern.kind = kind }
                        }), label: ContextRouteLocalization.string("Match"))
                        activitySpace
                    }
                }
                formRow(websitePattern.kind == .domain ? "Domain" : "Address") {
                    HStack(spacing: RouteEditorLayout.controlSpacing) {
                        TextField(websitePattern.kind == .domain ? "youtube.com" : "https://example.com/work/", text: $websitePattern.value)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(websitePattern.kind == .domain ? "Domain" : "Address")
                        if websitePattern.kind == .domain {
                            Toggle("Include subdomains", isOn: $websitePattern.includesSubdomains)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                        }
                        activitySpace
                    }
                }
                if let hint = websiteMatchHint {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var websiteMatchHint: LocalizedStringKey? {
        if !websitePattern.value.isEmpty && websitePattern.normalized == nil {
            return LocalizedStringKey(websitePattern.validationKey)
        }
        switch websitePattern.kind {
        case .domain: return nil
        case .urlPrefix: return "Matches addresses starting with this URL. Path, query, and fragment are case-sensitive."
        case .exactURL: return "Matches only this URL, including its path, query, and fragment."
        }
    }

    private var sourceAppCard: some View {
        SettingsCard(inset: RouteEditorLayout.cardInset) {
            formRow("Source app") {
                HStack(spacing: RouteEditorLayout.controlSpacing) {
                    AppIconView(appURL: BrowserCatalog.applicationURL(bundleIdentifier: sourceBundleIdentifier), symbol: "app.fill", size: RouteEditorLayout.iconSize)
                    Text(sourceName.isEmpty ? ContextRouteLocalization.string("Choose an app") : sourceName)
                        .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .help(sourceBundleIdentifier)
                    Spacer(minLength: RouteEditorLayout.controlSpacing)
                    Button("Choose app…", action: chooseSourceApplication).buttonStyle(.bordered).fixedSize()
                    activitySpace
                }
            }
        }
    }

    private var browserCard: some View {
        SettingsCard(inset: RouteEditorLayout.cardInset) {
            VStack(alignment: .leading, spacing: RouteEditorLayout.sectionSpacing) {
                formRow("Browser") {
                    HStack(spacing: RouteEditorLayout.controlSpacing) {
                        AppIconView(appURL: selectedBrowser?.appURL, symbol: "globe", size: RouteEditorLayout.iconSize)
                        SettingsPopup(options: browserOptions, selection: $browserBundleIdentifier,
                            label: ContextRouteLocalization.string("Browser"), isEnabled: !browsers.isEmpty)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        activitySpace
                    }
                }
                if let browser = selectedBrowser, BrowserCatalog.supportsProfiles(for: browser) {
                    Divider()
                    formRow("Profile") {
                        HStack(spacing: RouteEditorLayout.controlSpacing) {
                            Color.clear.frame(width: RouteEditorLayout.iconSize, height: RouteEditorLayout.rowHeight).accessibilityHidden(true)
                            profilePicker
                            profileActivity
                        }
                    }
                    profileFolderControls(for: browser)
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
        SettingsPopup(options: profileOptions, selection: $profileIdentifier,
            label: ContextRouteLocalization.string("Profile"), isEnabled: !isScanning)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var activitySpace: some View {
        Color.clear.frame(width: RouteEditorLayout.activityWidth, height: RouteEditorLayout.rowHeight)
            .accessibilityHidden(true)
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
        .frame(width: RouteEditorLayout.activityWidth, height: RouteEditorLayout.rowHeight)
    }

    @ViewBuilder
    private var profileFeedback: some View {
        if let failure = profileScan?.failureMessage {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if profileScan != nil, !profileSelectionIsValid, !isScanning {
            Text("This profile wasn't found in the selected folder. Choose it again or change the folder.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func profileFolderControls(for browser: BrowserInfo) -> some View {
        HStack(alignment: .top, spacing: RouteEditorLayout.controlSpacing) {
            Color.clear
                .frame(width: RouteEditorLayout.labelWidth + RouteEditorLayout.sectionSpacing + RouteEditorLayout.iconSize, height: 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RouteEditorLayout.controlSpacing) {
                Text((profileFolderPath as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).help(profileFolderPath)
                    .accessibilityLabel("Profile folder")
                    .accessibilityValue(profileFolderPath)
                HStack(spacing: RouteEditorLayout.controlSpacing) {
                    Button("Profile folder…", action: chooseUserDataDirectory)
                        .buttonStyle(.bordered)
                        .help(ContextRouteLocalization.format("Choose the folder containing %@, not an individual profile folder.",
                            arguments: [BrowserCatalog.metadataFileName(for: browser) ?? "profiles"]))
                    Button("Use default folder") {
                        userDataDirectory = BrowserCatalog.defaultUserDataDirectory(for: browser) ?? ""
                        profileIdentifier = ""
                        scanGeneration += 1
                    }
                    .buttonStyle(.bordered).disabled(usesDefaultProfileFolder)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            activitySpace
        }
    }

    private func formRow<Content: View>(_ title: LocalizedStringKey, alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: RouteEditorLayout.sectionSpacing) {
            Text(title).frame(width: RouteEditorLayout.labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: RouteEditorLayout.rowHeight, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: RouteEditorLayout.controlSpacing) {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            Button(isFallback ? LocalizedStringKey("Save") : hasReplacement ? LocalizedStringKey("Replace route") : LocalizedStringKey("Save route")) {
                if hasReplacement { confirmsReplacement = true } else { save() }
            }
            .primaryActionStyle().keyboardShortcut(.defaultAction)
            .disabled(!inputIsValid || selectedBrowser == nil || !profileSelectionIsValid || isScanning || !model.canEditSettings)
        }
        .padding(.horizontal, RouteEditorLayout.windowInset)
        .padding(.vertical, RouteEditorLayout.cardInset)
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
            if selectedBrowser != nil { profileIdentifier = "" }
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
        let target = BrowserTarget(browserBundleIdentifier: browser.bundleIdentifier, browserName: browser.name,
            profileIdentifier: profile?.id, profileName: profile?.name,
            userDataDirectory: BrowserCatalog.supportsProfiles(for: browser) && !usesDefaultProfileFolder ? userDataDirectory : nil)
        if isFallback {
            if model.setFallbackTarget(target) { dismiss() }
            return
        }
        if isWebsite {
            guard let pattern = websitePattern.normalized else { return }
            var updated = websiteRoute ?? WebsiteRoute(pattern: pattern, target: target)
            updated.pattern = pattern
            updated.target = target
            if model.add(updated) { dismiss() }
            return
        }
        var updated = route ?? SourceRoute(sourceBundleIdentifier: sourceBundleIdentifier, sourceName: sourceName,
            browserBundleIdentifier: browser.bundleIdentifier, browserName: browser.name,
            profileIdentifier: nil, profileName: nil, userDataDirectory: nil)
        updated.sourceBundleIdentifier = sourceBundleIdentifier
        updated.sourceName = sourceName.isEmpty ? sourceBundleIdentifier : sourceName
        updated.target = target
        if model.add(updated) { dismiss() }
    }
}
