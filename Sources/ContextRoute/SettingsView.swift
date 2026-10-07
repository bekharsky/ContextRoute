import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsSection: CaseIterable, Identifiable, Hashable {
    case routes
    case handlers
    case fallback
    case appearance

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .routes: "App routes"
        case .handlers: "Default handlers"
        case .fallback: "Fallback browser"
        case .appearance: "Appearance"
        }
    }

    var resolvedTitle: String {
        let key: String
        switch self {
        case .routes: key = "App routes"
        case .handlers: key = "Default handlers"
        case .fallback: key = "Fallback browser"
        case .appearance: key = "Appearance"
        }
        return ContextRouteLocalization.string(key)
    }

    var symbol: String {
        switch self {
        case .routes: "arrow.triangle.branch"
        case .handlers: "arrow.up.right.square"
        case .fallback: "globe"
        case .appearance: "slider.horizontal.3"
        }
    }
}

private enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RouterModel
    @AppStorage("app.contextroute.appearance") private var appearanceRawValue = AppearanceChoice.system.rawValue
    @AppStorage(InterfaceLanguage.defaultsKey) private var languageRawValue = InterfaceLanguage.english.rawValue
    @State private var browsers = BrowserCatalog.installedBrowsers()
    @State private var fallbackBrowserID = ""
    @State private var selectedSection: SettingsSection = .routes
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isEditingRoute = false
    @State private var editingRoute: SourceRoute?
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool
    @State private var sectionHistory: [SettingsSection] = [.routes]
    @State private var historyPosition = 0

    private var appearanceChoice: AppearanceChoice {
        AppearanceChoice(rawValue: appearanceRawValue) ?? .system
    }

    private var interfaceLanguage: InterfaceLanguage {
        InterfaceLanguage(rawValue: languageRawValue) ?? .english
    }

    private var filteredOverrides: [URLAppOverride] {
        guard !searchQuery.isEmpty else { return model.urlAppOverrides }
        let matches = model.urlAppOverrides.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
                || $0.matchSummary.localizedCaseInsensitiveContains(searchQuery)
                || $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
        let matchesSectionName = "default handlers link handlers redirects обработчики ссылок"
            .localizedCaseInsensitiveContains(searchQuery)
        return matches.isEmpty && matchesSectionName ? model.urlAppOverrides : matches
    }

    private var filteredRoutes: [SourceRoute] {
        guard !searchQuery.isEmpty else { return model.sourceRoutes }
        let matches = model.sourceRoutes.filter { route in
            [
                route.sourceName,
                route.sourceBundleIdentifier,
                route.browserName,
                route.profileName ?? "",
                route.profileIdentifier ?? "",
                route.userDataDirectory ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(searchQuery) }
        }
        let matchesSectionName = "app routes source app rules applications rules browser profile маршруты приложения правила приложений"
            .localizedCaseInsensitiveContains(searchQuery)
        return matches.isEmpty && matchesSectionName ? model.sourceRoutes : matches
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingSections: [SettingsSection] {
        guard !searchQuery.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            searchEntries(for: section).contains {
                $0.searchableText.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    private var selectedFallbackBrowser: BrowserInfo? {
        browsers.first { $0.bundleIdentifier == fallbackBrowserID }
    }

    private var sidebarSelection: Binding<SettingsSection> {
        Binding(
            get: { selectedSection },
            set: { selectSection($0) })
    }

    private var canNavigateBack: Bool { historyPosition > 0 }
    private var canNavigateForward: Bool { historyPosition < sectionHistory.count - 1 }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 238, max: 255)
        } detail: {
            Group {
                if !searchQuery.isEmpty && matchingSections.isEmpty {
                    ContentUnavailableView(
                        "No settings found",
                        systemImage: "magnifyingglass",
                        description: Text("Try another name or keyword."))
                } else {
                    switch selectedSection {
                    case .routes: routesTab
                    case .handlers: handlersTab
                    case .fallback: fallbackTab
                    case .appearance: appearanceTab
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .topLeading) {
            SettingsWindowToolbarBridge(
                title: selectedSection.resolvedTitle,
                showsRefresh: selectedSection != .appearance,
                visibility: $columnVisibility,
                canNavigateBack: canNavigateBack,
                canNavigateForward: canNavigateForward,
                onBack: navigateBack,
                onForward: navigateForward,
                onRefresh: refreshBrowsers)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .preferredColorScheme(appearanceChoice.colorScheme)
        .environment(\.locale, interfaceLanguage.locale)
        .onAppear(perform: syncFallbackSelection)
        .onChange(of: searchText) { _, _ in
            selectFirstMatchingSectionIfNeeded()
        }
        .sheet(isPresented: $isEditingRoute) {
            RouteEditorView(model: model, browsers: browsers, route: editingRoute)
        }
        .onChange(of: isEditingRoute) { _, isOpen in
            if !isOpen { editingRoute = nil }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Search settings")
                    .submitLabel(.search)
                if !searchQuery.isEmpty {
                    Button {
                        searchText = ""
                        searchIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List(selection: sidebarSelection) {
                ForEach(matchingSections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                if !searchQuery.isEmpty && matchingSections.isEmpty {
                    Label("No settings found", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isContextRouteDefaultHandler ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.isContextRouteDefaultHandler ? "Link handling is on" : "Link handling is off")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .background {
            Color(nsColor: .underPageBackgroundColor)
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var routesTab: some View {
        pageContent {
            SectionIntro("Choose which browser and profile should open links from each app.")

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source app rules")
                        .font(.headline)
                    Text("Links without a matching rule use the fallback browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: addRoute) {
                    Label("Add app route", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if model.sourceRoutes.isEmpty {
                ContentUnavailableView {
                    Label("No routes yet", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add an app, browser, and profile to route its links automatically.")
                }
                .padding(.vertical, 16)
            } else if filteredRoutes.isEmpty {
                ContentUnavailableView(
                    "No routes found",
                    systemImage: "magnifyingglass",
                    description: Text("Try another name or keyword."))
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredRoutes) { route in
                        RouteRow(
                            route: route,
                            onEdit: {
                                editingRoute = route
                                isEditingRoute = true
                            },
                            onDelete: { model.remove(route) })
                    }
                }
            }
        }
    }

    private var handlersTab: some View {
        pageContent {
            SectionIntro("Send matching links straight to their apps. Other links follow your app routes.")

            if filteredOverrides.isEmpty {
                ContentUnavailableView(
                    "No handlers found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different app name or domain."))
                    .padding(.vertical, 18)
            } else {
                SettingsCard(inset: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredOverrides.enumerated()), id: \.element.id) { index, item in
                            AppOverrideRow(override: item) { enabled in
                                model.setOverrideEnabled(id: item.id, enabled: enabled)
                            }
                            if index < filteredOverrides.count - 1 {
                                Divider().padding(.leading, 56).padding(.trailing, 14)
                            }
                        }
                    }
                }

                Text("Handlers follow Yojam's built-in URL rules. If an app isn't installed, the link uses its regular route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fallbackTab: some View {
        pageContent {
            SectionIntro("Choose where links go when no app route matches.")

            SettingsCard {
                VStack(spacing: 15) {
                    HStack(spacing: 12) {
                        AppIconView(appURL: selectedFallbackBrowser?.appURL, symbol: "globe", size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fallback browser")
                                .font(.headline)
                            Text("Used when no source app rule matches.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Picker("Fallback browser", selection: $fallbackBrowserID) {
                            Text("Choose browser").tag("")
                            ForEach(browsers) { browser in
                                Text(browser.name).tag(browser.bundleIdentifier)
                            }
                        }
                        .frame(width: 250)
                        .onChange(of: fallbackBrowserID) { _, newValue in
                            model.setFallbackBrowser(browsers.first { $0.bundleIdentifier == newValue })
                        }
                    }

                    Divider()

                    HStack(spacing: 9) {
                        Image(systemName: model.isContextRouteDefaultHandler
                            ? "checkmark.circle.fill"
                            : "info.circle")
                            .foregroundStyle(model.isContextRouteDefaultHandler ? .green : .secondary)
                        Text(model.isContextRouteDefaultHandler
                            ? "ContextRoute handles http and https links."
                            : "Set ContextRoute as your http and https handler to enable routing.")
                            .font(.callout)
                        Spacer(minLength: 8)
                        Button("Set as link handler") {
                            model.registerAsDefaultHandler()
                        }
                        .primaryActionStyle()
                        .disabled(model.fallbackBrowserBundleIdentifier == nil)
                    }
                }
            }

            if !model.lastRoute.isEmpty {
                SettingsCard(inset: 12) {
                    Label(
                        L10n.format("Last route: %@", arguments: [model.lastRoute]),
                        systemImage: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Button("Use current default browser") {
                _ = model.captureCurrentDefaultBrowserIfPossible()
                syncFallbackSelection()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("If another link router is currently the default, choose a browser here. ContextRoute won't use another router as its fallback browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearanceTab: some View {
        pageContent {
            SectionIntro("Choose how ContextRoute looks and which language it uses.")

            SettingsCard {
                VStack(alignment: .leading, spacing: 13) {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                        .font(.headline)
                    Picker("Appearance", selection: $appearanceRawValue) {
                        Text("System").tag(AppearanceChoice.system.rawValue)
                        Text("Light").tag(AppearanceChoice.light.rawValue)
                        Text("Dark").tag(AppearanceChoice.dark.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text("System follows the appearance set in macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard {
                HStack(spacing: 12) {
                    Label("Language", systemImage: "character.bubble")
                        .font(.headline)
                    Spacer()
                    Picker("Language", selection: $languageRawValue) {
                        Text("English").tag(InterfaceLanguage.english.rawValue)
                        Text("Русский").tag(InterfaceLanguage.russian.rawValue)
                        Text("System language").tag(InterfaceLanguage.system.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190, alignment: .trailing)
                }
            }

            Text("English is the default. Additional translations can be added in the app's localization files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pageContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: 810, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 21)
                .padding(.vertical, 18)
        }
        .scrollIndicators(.automatic)
    }

    private func addRoute() {
        editingRoute = nil
        isEditingRoute = true
    }

    private func refreshBrowsers() {
        browsers = BrowserCatalog.installedBrowsers()
    }

    private func syncFallbackSelection() {
        fallbackBrowserID = model.fallbackBrowserBundleIdentifier ?? ""
    }

    private func selectSection(_ section: SettingsSection) {
        guard section != selectedSection else { return }
        if historyPosition < sectionHistory.count - 1 {
            sectionHistory = Array(sectionHistory.prefix(historyPosition + 1))
        }
        sectionHistory.append(section)
        historyPosition = sectionHistory.count - 1
        selectedSection = section
    }

    private func navigateBack() {
        guard canNavigateBack else { return }
        historyPosition -= 1
        selectedSection = sectionHistory[historyPosition]
    }

    private func navigateForward() {
        guard canNavigateForward else { return }
        historyPosition += 1
        selectedSection = sectionHistory[historyPosition]
    }

    private func selectFirstMatchingSectionIfNeeded() {
        guard !searchQuery.isEmpty,
              !matchingSections.contains(selectedSection),
              let first = matchingSections.first else { return }
        selectSection(first)
    }

    private func searchEntries(for section: SettingsSection) -> [(title: String, searchableText: String)] {
        switch section {
        case .routes:
            return [("App routes", "app routes source app rules applications rules browser profile маршруты приложения правила приложений")]
                + model.sourceRoutes.map { route in
                    let terms = [
                        route.sourceName, route.sourceBundleIdentifier, route.browserName,
                        route.profileName ?? "", route.profileIdentifier ?? "",
                        route.userDataDirectory ?? "", "browser profile app route"
                    ].joined(separator: " ")
                    return (route.sourceName, terms)
                }
        case .handlers:
            return [("Default handlers", "default handlers link handlers redirects обработчики ссылок")]
                + model.urlAppOverrides.map { item in
                    (item.name, [item.name, item.id, item.matchSummary].joined(separator: " "))
                }
        case .fallback:
            return [("Fallback browser", "fallback browser default browser резервный браузер браузер по умолчанию")]
                + browsers.map { ($0.name, "\($0.name) \($0.bundleIdentifier)") }
        case .appearance:
            return [
                ("Appearance", "appearance theme system light dark внешний вид системная светлая тёмная"),
                ("Language", "language english russian system язык английский русский системный")
            ]
        }
    }
}

private struct RouteRow: View {
    let route: SourceRoute
    let onEdit: () -> Void
    let onDelete: () -> Void

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
                Text(route.sourceName)
                    .font(.body.weight(.semibold))
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
            }
            .padding(.leading, 1)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                RouteActionButton(symbol: "pencil", title: "Edit route", action: onEdit)
                RouteActionButton(symbol: "trash", title: "Delete route", isDestructive: true, action: onDelete)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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

private struct SettingsWindowToolbarBridge: NSViewRepresentable {
    let title: String
    let showsRefresh: Bool
    @Binding var visibility: NavigationSplitViewVisibility
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ToolbarAnchorView {
        let view = ToolbarAnchorView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: ToolbarAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(
            title: title,
            showsRefresh: showsRefresh,
            visibility: $visibility,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward,
            onBack: onBack,
            onForward: onForward,
            onRefresh: onRefresh)
        nsView.windowDidChange = { [weak coordinator] window in
            coordinator?.install(in: window)
        }
        coordinator.install(in: nsView.window)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        private static let toolbarIdentifier = NSToolbar.Identifier("ContextRoute.SettingsToolbar")
        private static let sidebarIdentifier = NSToolbarItem.Identifier("ContextRoute.SidebarToggle")
        private static let navigationIdentifier = NSToolbarItem.Identifier("ContextRoute.Navigation")
        private static let backIdentifier = NSToolbarItem.Identifier("ContextRoute.Back")
        private static let forwardIdentifier = NSToolbarItem.Identifier("ContextRoute.Forward")
        private static let titleIdentifier = NSToolbarItem.Identifier("ContextRoute.SectionTitle")
        private static let refreshIdentifier = NSToolbarItem.Identifier("ContextRoute.Refresh")

        private weak var window: NSWindow?
        private var toolbar: NSToolbar?
        private var title = ""
        private var showsRefresh = true
        private var visibility: Binding<NavigationSplitViewVisibility>?
        private var canNavigateBack = false
        private var canNavigateForward = false
        private var onBack: () -> Void = {}
        private var onForward: () -> Void = {}
        private var onRefresh: () -> Void = {}
        private var sidebarItem: NSToolbarItem?
        private var navigationItem: NSToolbarItemGroup?
        private var titleItem: NSToolbarItem?
        private var titleField: NSTextField?

        func update(
            title: String,
            showsRefresh: Bool,
            visibility: Binding<NavigationSplitViewVisibility>,
            canNavigateBack: Bool,
            canNavigateForward: Bool,
            onBack: @escaping () -> Void,
            onForward: @escaping () -> Void,
            onRefresh: @escaping () -> Void
        ) {
            self.title = title
            self.showsRefresh = showsRefresh
            self.visibility = visibility
            self.canNavigateBack = canNavigateBack
            self.canNavigateForward = canNavigateForward
            self.onBack = onBack
            self.onForward = onForward
            self.onRefresh = onRefresh

            updateToolbarItems()
            window?.title = title
        }

        func install(in window: NSWindow?) {
            guard let window, visibility != nil else { return }
            self.window = window
            window.title = title
            window.titleVisibility = .hidden
            window.toolbarStyle = .unifiedCompact

            guard window.toolbar?.identifier != Self.toolbarIdentifier else { return }

            let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
            window.toolbar = toolbar
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            // Keep the tracking separator first so every control stays in the content toolbar.
            [
                .sidebarTrackingSeparator,
                Self.sidebarIdentifier,
                Self.navigationIdentifier,
                Self.titleIdentifier,
                .flexibleSpace
            ]
            + (showsRefresh ? [Self.refreshIdentifier] : [])
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .sidebarTrackingSeparator,
                Self.sidebarIdentifier,
                Self.navigationIdentifier,
                Self.titleIdentifier,
                .space,
                .flexibleSpace,
                Self.refreshIdentifier
            ]
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch itemIdentifier {
            case Self.sidebarIdentifier:
                let item = makeItem(
                    identifier: itemIdentifier,
                    label: sidebarLabel,
                    symbol: sidebarSymbol,
                    action: #selector(toggleSidebar(_:)))
                sidebarItem = item
                return item

            case Self.navigationIdentifier:
                let back = makeItem(
                    identifier: Self.backIdentifier,
                    label: ContextRouteLocalization.string("Back"),
                    symbol: "chevron.backward",
                    action: #selector(goBack(_:)))
                let forward = makeItem(
                    identifier: Self.forwardIdentifier,
                    label: ContextRouteLocalization.string("Forward"),
                    symbol: "chevron.forward",
                    action: #selector(goForward(_:)))
                back.isEnabled = canNavigateBack
                forward.isEnabled = canNavigateForward

                let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
                group.label = ContextRouteLocalization.string("Back and forward")
                group.paletteLabel = group.label
                group.controlRepresentation = .expanded
                group.selectionMode = .momentary
                group.subitems = [back, forward]
                navigationItem = group
                return group

            case Self.titleIdentifier:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = title
                item.paletteLabel = title
                let field = NSTextField(labelWithString: title)
                field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 1
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                field.sizeToFit()
                item.view = field
                titleItem = item
                titleField = field
                return item

            case Self.refreshIdentifier:
                return makeItem(
                    identifier: itemIdentifier,
                    label: ContextRouteLocalization.string("Refresh apps and browsers"),
                    symbol: "arrow.clockwise",
                    action: #selector(refresh(_:)))

            default:
                return nil
            }
        }

        private var sidebarSymbol: String {
            visibility?.wrappedValue == .detailOnly ? "sidebar.right" : "sidebar.left"
        }

        private var sidebarLabel: String {
            ContextRouteLocalization.string(visibility?.wrappedValue == .detailOnly ? "Show sidebar" : "Hide sidebar")
        }

        private func makeItem(
            identifier: NSToolbarItem.Identifier,
            label: String,
            symbol: String,
            action: Selector
        ) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            return item
        }

        private func updateToolbarItems() {
            if let sidebarItem {
                sidebarItem.image = NSImage(systemSymbolName: sidebarSymbol, accessibilityDescription: sidebarLabel)
                sidebarItem.label = sidebarLabel
                sidebarItem.paletteLabel = sidebarLabel
                sidebarItem.toolTip = sidebarLabel
            }
            if let navigationItem, navigationItem.subitems.count == 2 {
                navigationItem.subitems[0].isEnabled = canNavigateBack
                navigationItem.subitems[1].isEnabled = canNavigateForward
            }
            if let titleField {
                titleField.stringValue = title
                titleField.sizeToFit()
                titleField.invalidateIntrinsicContentSize()
                titleItem?.label = title
                titleItem?.paletteLabel = title
            }
            if let toolbar {
                let refreshIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.refreshIdentifier }
                if showsRefresh && refreshIndex == nil {
                    toolbar.insertItem(withItemIdentifier: Self.refreshIdentifier, at: toolbar.items.count)
                } else if !showsRefresh, let refreshIndex {
                    toolbar.removeItem(at: refreshIndex)
                }
            }
            toolbar?.validateVisibleItems()
        }

        @objc private func toggleSidebar(_ sender: Any?) {
            guard let visibility else { return }
            visibility.wrappedValue = visibility.wrappedValue == .detailOnly ? .all : .detailOnly
        }

        @objc private func goBack(_ sender: Any?) {
            guard canNavigateBack else { return }
            onBack()
        }

        @objc private func goForward(_ sender: Any?) {
            guard canNavigateForward else { return }
            onForward()
        }

        @objc private func refresh(_ sender: Any?) {
            guard showsRefresh else { return }
            onRefresh()
        }
    }
}

private final class ToolbarAnchorView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

private struct AppOverrideRow: View {
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
            }
            Spacer(minLength: 10)
            Toggle(override.name, isOn: Binding(get: { override.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(override.isEnabled ? "Turn handler off" : "Turn handler on")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}

private struct RouteEditorView: View {
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

    init(model: RouterModel, browsers: [BrowserInfo], route: SourceRoute?) {
        self.model = model
        self.browsers = browsers
        self.route = route
        let selectedBrowser = browsers.first { $0.bundleIdentifier == route?.browserBundleIdentifier }
            ?? browsers.first
        _sourceBundleIdentifier = State(initialValue: route?.sourceBundleIdentifier ?? "")
        _sourceName = State(initialValue: route?.sourceName ?? "")
        _browserBundleIdentifier = State(initialValue: route?.browserBundleIdentifier ?? selectedBrowser?.bundleIdentifier ?? "")
        let initialDirectory = route?.userDataDirectory
            ?? selectedBrowser.flatMap { BrowserCatalog.defaultUserDataDirectory(for: $0) }
            ?? ""
        _userDataDirectory = State(initialValue: initialDirectory)
        _profileIdentifier = State(initialValue: route?.profileIdentifier ?? "")
        _profileScan = State(initialValue: nil)
    }

    private var selectedBrowser: BrowserInfo? {
        browsers.first { $0.bundleIdentifier == browserBundleIdentifier }
    }

    private var profiles: [BrowserProfile] { profileScan?.profiles ?? [] }

    private var profileSelectionIsValid: Bool {
        profileIdentifier.isEmpty || profiles.contains { $0.id == profileIdentifier }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text(route == nil ? "New app route" : "Edit app route")
                    .font(.title2.weight(.semibold))
                SectionIntro("Choose a source app, browser, and optional profile.")
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("SOURCE APP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 11) {
                        AppIconView(
                            appURL: BrowserCatalog.applicationURL(bundleIdentifier: sourceBundleIdentifier),
                            symbol: "app.fill",
                            size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourceName.isEmpty ? "Choose an app" : sourceName)
                                .font(.body.weight(.medium))
                            if !sourceBundleIdentifier.isEmpty {
                                Text(sourceBundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Choose app…", action: chooseSourceApplication)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("BROWSER AND PROFILE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        AppIconView(appURL: selectedBrowser?.appURL, symbol: "globe", size: 30)
                        Picker("Browser", selection: $browserBundleIdentifier) {
                            ForEach(browsers) { browser in
                                Text(browser.name).tag(browser.bundleIdentifier)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: browserBundleIdentifier) { _, newValue in
                            profileIdentifier = ""
                            if let browser = browsers.first(where: { $0.bundleIdentifier == newValue }) {
                                userDataDirectory = BrowserCatalog.defaultUserDataDirectory(for: browser) ?? ""
                                refreshProfiles()
                            }
                        }
                    }

                    if let selectedBrowser, BrowserCatalog.supportsProfiles(for: selectedBrowser) {
                        HStack(spacing: 10) {
                            Picker("Profile", selection: $profileIdentifier) {
                                Text("Use browser default").tag("")
                                ForEach(profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .frame(maxWidth: 330)
                            Spacer(minLength: 8)
                            Button("Profile folder…", action: chooseUserDataDirectory)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Reset") {
                                userDataDirectory = BrowserCatalog.defaultUserDataDirectory(for: selectedBrowser) ?? ""
                                profileIdentifier = ""
                                refreshProfiles()
                            }
                            .buttonStyle(.plain)
                        }
                        Text(userDataDirectory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let profileScan {
                            if let failure = profileScan.failureMessage {
                                Label(failure, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("If macOS asks for browser data access, allow it and refresh the profile list.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label(
                                    L10n.format("Profile list loaded · %@ found", arguments: [String(profileScan.profiles.count)]),
                                    systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        Button("Refresh profile list", action: refreshProfiles)
                            .buttonStyle(.link)
                        if !profileSelectionIsValid {
                            Text("This profile wasn't found in the selected folder. Choose it again or change the folder.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Profile selection isn't available for this browser. Links will open the browser normally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save route", action: save)
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourceBundleIdentifier.isEmpty || browserBundleIdentifier.isEmpty || !profileSelectionIsValid)
            }
        }
        .padding(20)
        .frame(width: 690, height: 590)
        .environment(\.locale, InterfaceLanguage.current.locale)
        .onAppear(perform: refreshProfiles)
    }

    private func chooseSourceApplication() {
        let panel = NSOpenPanel()
        panel.title = ContextRouteLocalization.string("Choose the source app")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else { return }
        sourceBundleIdentifier = bundleIdentifier
        sourceName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func chooseUserDataDirectory() {
        let panel = NSOpenPanel()
        let metadataName = selectedBrowser.flatMap(BrowserCatalog.metadataFileName(for:)) ?? "profile metadata"
        panel.title = ContextRouteLocalization.format(
            "Choose the folder containing %@", arguments: [metadataName])
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        if let selectedBrowser {
            let preferredPath = userDataDirectory.isEmpty
                ? BrowserCatalog.defaultUserDataDirectory(for: selectedBrowser)
                : BrowserCatalog.expandHome(userDataDirectory)
            if let preferredPath {
                panel.directoryURL = nearestExistingDirectory(
                    to: URL(fileURLWithPath: preferredPath, isDirectory: true))
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        userDataDirectory = url.path
        profileIdentifier = ""
        refreshProfiles()
    }

    private func nearestExistingDirectory(to directory: URL) -> URL {
        var candidate = directory.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private func refreshProfiles() {
        guard let selectedBrowser else {
            profileScan = nil
            return
        }
        profileScan = BrowserCatalog.profileScan(
            for: selectedBrowser,
            userDataDirectory: userDataDirectory.isEmpty ? nil : userDataDirectory)
    }

    private func save() {
        guard let browser = selectedBrowser else { return }
        let selectedProfile = profiles.first { $0.id == profileIdentifier }
        var updatedRoute = route ?? SourceRoute(
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceName: sourceName,
            browserBundleIdentifier: browser.bundleIdentifier,
            browserName: browser.name,
            profileIdentifier: nil,
            profileName: nil,
            userDataDirectory: nil)
        updatedRoute.sourceBundleIdentifier = sourceBundleIdentifier
        updatedRoute.sourceName = sourceName.isEmpty ? sourceBundleIdentifier : sourceName
        updatedRoute.browserBundleIdentifier = browser.bundleIdentifier
        updatedRoute.browserName = browser.name
        updatedRoute.profileIdentifier = selectedProfile?.id
        updatedRoute.profileName = selectedProfile?.name
        updatedRoute.userDataDirectory = BrowserCatalog.supportsProfiles(for: browser)
            ? userDataDirectory
            : nil
        model.add(updatedRoute)
        dismiss()
    }
}

private struct SectionIntro: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsCard<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder var content: Content

    init(inset: CGFloat = 15, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        content
            .padding(inset)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AppIconView: View {
    let appURL: URL?
    let symbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

private enum L10n {
    static func format(_ key: String, arguments: [String]) -> String {
        ContextRouteLocalization.format(key, arguments: arguments)
    }
}
