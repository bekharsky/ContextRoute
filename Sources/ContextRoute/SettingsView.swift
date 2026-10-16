import AppKit
import SwiftUI

private enum SettingsSheet {
    case route(SourceRoute?)
    case website(WebsiteRoute?)
    case fallback
    case checker
}

struct SettingsView: View {
    @ObservedObject var model: RouterModel
    let focusVisibility: SettingsFocusVisibility
    @AppStorage(AppearanceChoice.defaultsKey) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(InterfaceLanguage.defaultsKey) private var language = InterfaceLanguage.english.rawValue
    @State private var browsers = BrowserCatalog.installedBrowsers()
    @State private var selectedSection: SettingsSection = .routes
    @State private var sheet: SettingsSheet?
    @State private var searchText = ""
    @State private var highlightedAnchor: String?
    @State private var sectionHistory: [SettingsSection] = [.routes]
    @State private var historyPosition = 0

    private var appearanceChoice: AppearanceChoice { AppearanceChoice(rawValue: appearance) ?? .system }
    private var interfaceLanguage: InterfaceLanguage { InterfaceLanguage(rawValue: language) ?? .english }
    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchResults: [SettingsSearchResult] { SettingsSearchIndex.results(for: searchQuery, model: model, browsers: browsers) }
    private var hasAvailableFallback: Bool { browsers.contains { $0.bundleIdentifier == model.fallbackBrowserBundleIdentifier } }
    private var sidebarSelection: Binding<SettingsSection> { Binding(get: { selectedSection }, set: selectSection) }
    private var isPresentingSheet: Binding<Bool> { Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }) }

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case let .route(route): RouteEditorView(model: model, browsers: browsers, route: route)
        case let .website(route): RouteEditorView(model: model, browsers: browsers, context: .website(route))
        case .fallback: RouteEditorView(model: model, browsers: browsers, context: .fallback)
        case .checker: RouteCheckerView(model: model)
        case nil: EmptyView()
        }
    }

    var body: some View {
        SettingsSplitContainer(
            sidebar: AnyView(SettingsFocusContent(focusVisibility: focusVisibility,
                content: sidebar.environment(\.locale, interfaceLanguage.locale))),
            sidebarState: .init(selectedSection: selectedSection, searchQuery: searchQuery,
                searchResults: searchQuery.isEmpty ? [] : searchResults,
                isDefaultHandler: model.isContextRouteDefaultHandler,
                language: language, appearance: appearance),
            detail: AnyView(SettingsFocusContent(focusVisibility: focusVisibility,
                content: detail.environment(\.locale, interfaceLanguage.locale))),
            sheetContent: AnyView(SettingsFocusContent(focusVisibility: focusVisibility,
                content: sheetContent.environment(\.locale, interfaceLanguage.locale)
                    .preferredColorScheme(appearanceChoice.colorScheme)
                    .presentationSizing(.fitted))),
            isPresentingSheet: isPresentingSheet,
            focusVisibility: focusVisibility,
            searchText: $searchText,
            title: selectedSection.resolvedTitle,
            showsRefresh: true,
            canNavigateBack: historyPosition > 0,
            canNavigateForward: historyPosition < sectionHistory.count - 1,
            onBack: { navigateHistory(by: -1) },
            onForward: { navigateHistory(by: 1) },
            onRefresh: refreshBrowsers)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .preferredColorScheme(appearanceChoice.colorScheme)
        .environment(\.locale, interfaceLanguage.locale)
        .onAppear { model.refreshDefaultHandlerStatus() }
        .onChange(of: appearance) { _, _ in NSApp.appearance = appearanceChoice.nativeAppearance }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.showLinkSetupNotification)) { _ in
            searchText = ""
            selectSection(hasAvailableFallback ? .routes : .settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.showRoutingFailureNotification)) { _ in
            searchText = ""
            if let id = model.routingIssue?.routeID {
                selectSection(model.websiteRoutes.contains { $0.id == id } ? .websites : .routes)
            } else { selectSection(.settings) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if searchQuery.isEmpty {
                List(selection: sidebarSelection) {
                    ForEach(SettingsSection.allCases) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            sidebarIcon(for: section)
                        }
                        .tag(section)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            } else {
                List(selection: Binding<String?>(get: { nil }, set: { id in
                    if let result = searchResults.first(where: { $0.id == id }) { openSearchResult(result) }
                })) {
                    Section("Search results") {
                        ForEach(searchResults) { result in
                            HStack(spacing: 8) {
                                sidebarIcon(for: result.section).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).lineLimit(1)
                                    Text(result.section.resolvedTitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }.tag(result.id).help("\(result.section.resolvedTitle) → \(result.title)")
                        }
                        if searchResults.isEmpty {
                            Text("No settings found").foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            HStack(spacing: 8) {
                Circle().fill(model.isContextRouteDefaultHandler ? Color.green : .orange).frame(width: 8, height: 8)
                Text(model.isContextRouteDefaultHandler ? LocalizedStringKey("Link handling is on") : LocalizedStringKey("Link handling is off"))
                    .font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
        }
    }

    private func sidebarIcon(for section: SettingsSection) -> some View {
        SettingsSectionIcon(section: section)
    }

    private var detail: some View {
        pageContent {
            switch selectedSection {
            case .routes: routesPage
            case .websites: websitesPage
            case .handlers: handlersPage
            case .settings:
                SettingsPreferencesView(model: model, browsers: browsers, appearance: $appearance,
                    language: $language, highlightedAnchor: highlightedAnchor, onEditFallback: { sheet = .fallback })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var routesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionIntro("Choose which browser and profile should open links from each app.")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source app rules").font(.headline)
                    Text("Links without a matching rule use the fallback browser.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { sheet = .route(nil) } label: { Label("Add app route", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.regular).disabled(!model.canEditSettings)
            }
            if model.sourceRoutes.isEmpty {
                ContentUnavailableView {
                    Label("No routes yet", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add an app, browser, and profile to route its links automatically.")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.sourceRoutes) { route in
                        RouteRow(route: route,
                            onEdit: { sheet = .route(route) }, onDelete: { model.remove(route) },
                            onToggle: { model.setRouteEnabled(id: route.id, enabled: $0) }, issue: model.routeIssues[route.id])
                            .disabled(!model.canEditSettings)
                            .searchTarget(route.id.uuidString, highlighted: highlightedAnchor)
                    }
                }
            }
            HStack {
                Button { sheet = .checker } label: { Label("Check route…", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(.bordered).searchTarget("check", highlighted: highlightedAnchor)
                Spacer()
                if model.canUndo {
                    Button("Undo", action: model.undo).buttonStyle(.bordered).help(model.undoActionName)
                }
            }
        }
    }

    private var handlersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionIntro("Send matching links straight to their apps. Website routes take priority.")
            SettingsCard(inset: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.urlAppOverrides.enumerated()), id: \.element.id) { index, item in
                        AppOverrideRow(override: item) { model.setOverrideEnabled(id: item.id, enabled: $0) }
                            .disabled(!model.canEditSettings)
                            .searchTarget(item.id, highlighted: highlightedAnchor)
                        if index < model.urlAppOverrides.count - 1 {
                            Divider().padding(.leading, 56).padding(.trailing, 14)
                        }
                    }
                }
            }
            Text("If an app isn't installed, its links follow your app routes or use the fallback browser.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var websitesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionIntro("Choose a browser and profile for a domain or address, regardless of the source app.")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Website rules").font(.headline)
                    Text("More specific rules take priority. Regular expressions are not needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { sheet = .website(nil) } label: { Label("Add website route", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.regular).disabled(!model.canEditSettings)
            }
            if model.websiteRoutes.isEmpty {
                ContentUnavailableView {
                    Label("No website routes yet", systemImage: "globe")
                } description: {
                    Text("For example, open youtube.com in your personal browser profile.")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.websiteRoutes) { route in
                        WebsiteRouteRow(route: route, onEdit: { sheet = .website(route) }, onDelete: { model.remove(route) },
                            onToggle: { model.setWebsiteRouteEnabled(id: route.id, enabled: $0) }, issue: model.routeIssues[route.id])
                            .disabled(!model.canEditSettings)
                            .searchTarget(route.id.uuidString, highlighted: highlightedAnchor)
                    }
                }
            }
            HStack {
                Button { sheet = .checker } label: { Label("Check route…", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(.bordered)
                Spacer()
                if model.canUndo { Button("Undo", action: model.undo).buttonStyle(.bordered).help(model.undoActionName) }
            }
        }
    }

    private func pageContent<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0).id("top")
                    if let error = model.storageError { storageBanner(error) }
                    if let issue = model.routingIssue { routingBanner(issue) }
                    if !model.isContextRouteDefaultHandler { defaultBrowserSetup }
                    content()
                }
                .frame(maxWidth: 810, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 21).padding(.vertical, 18)
            }
            .scrollIndicators(.automatic)
            .onAppear { if let anchor = highlightedAnchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } } }
            .onChange(of: highlightedAnchor) { _, anchor in
                if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
            }
        }
    }

    private func storageBanner(_ error: LocalizedMessage) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(error.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                HStack {
                    if model.recovery == .backup { Button("Restore backup", action: model.restoreBackup).buttonStyle(.bordered) }
                    if model.recovery != nil {
                        Button("Try again", action: model.reloadSettings).buttonStyle(.bordered)
                        Button("Import settings…") { selectSection(.settings); highlightedAnchor = "transfer" }.buttonStyle(.bordered)
                    } else {
                        Text("Changes were not saved. Try the action again.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss", action: model.clearStorageError).buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func routingBanner(_ issue: RoutingIssue) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(issue.message.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                Text(issue.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(issue.url.absoluteString)
                HStack {
                    if issue.needsAttention {
                        Button("Retry in fallback browser") { model.retryInFallback(issue.url) }.buttonStyle(.bordered)
                    }
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(issue.url.absoluteString, forType: .string)
                    }.buttonStyle(.bordered)
                    Spacer()
                    Button("Dismiss", action: model.dismissRoutingIssue).buttonStyle(.bordered)
                }
                if let id = issue.routeID, let route = model.sourceRoutes.first(where: { $0.id == id }) {
                    Button("Edit route") { sheet = .route(route) }.buttonStyle(.link).disabled(!model.canEditSettings)
                } else if let id = issue.routeID, let route = model.websiteRoutes.first(where: { $0.id == id }) {
                    Button("Edit route") { sheet = .website(route) }.buttonStyle(.link).disabled(!model.canEditSettings)
                }
            }
        }
    }

    private var defaultBrowserSetup: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.tint).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable link routing").font(.headline)
                        Text("Make ContextRoute your default browser so links follow your rules. Other links will open in your fallback browser.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = model.defaultHandlerError { Text(error.text).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    if !hasAvailableFallback {
                        Text("Choose a fallback browser first.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(model.isSettingDefaultHandler ? LocalizedStringKey("Setting default browser…") : LocalizedStringKey("Make default browser")) {
                        if !hasAvailableFallback { selectSection(.settings); highlightedAnchor = "fallback" }
                        else { model.registerAsDefaultHandler() }
                    }.primaryActionStyle().disabled(model.isSettingDefaultHandler || !model.canEditSettings)
                }
            }
        }
    }

    private func refreshBrowsers() {
        let installedBrowsers = BrowserCatalog.installedBrowsers()
        if browsers != installedBrowsers { browsers = installedBrowsers }
        model.refreshDefaultHandlerStatus()
        model.refreshRoutingCache()
    }

    private func selectSection(_ section: SettingsSection) {
        searchText = ""
        highlightedAnchor = nil
        guard section != selectedSection else { return }
        if historyPosition < sectionHistory.count - 1 { sectionHistory = Array(sectionHistory.prefix(historyPosition + 1)) }
        sectionHistory.append(section)
        historyPosition = sectionHistory.count - 1
        selectedSection = section
    }

    private func navigateHistory(by offset: Int) {
        let position = historyPosition + offset
        guard sectionHistory.indices.contains(position) else { return }
        searchText = ""
        highlightedAnchor = nil
        historyPosition = position
        selectedSection = sectionHistory[position]
    }

    private func openSearchResult(_ result: SettingsSearchResult) {
        selectSection(result.section)
        highlightedAnchor = result.anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if highlightedAnchor == result.anchor { highlightedAnchor = nil }
        }
    }
}

private struct SettingsSectionIcon: View {
    let section: SettingsSection
    @Environment(\.self) private var environment

    private var color: Color {
        // Selection can lose emphasis while its window remains active.
        if environment.backgroundProminence == .increased { return .white }
        if !environment.appearsActive { return Color(nsColor: .secondaryLabelColor) }
        return .accentColor
    }

    var body: some View {
        Image(systemName: section.symbol)
            .symbolVariant(.none)
            .symbolRenderingMode(.monochrome)
            // Use a concrete foreground instead of the sidebar's automatic icon tint.
            .foregroundStyle(color.resolve(in: environment))
            .symbolEffectsRemoved()
            .contentTransition(.identity)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}
