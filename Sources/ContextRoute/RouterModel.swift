import AppKit
import Combine
import Foundation

struct RoutingIssue: Identifiable {
    let id = UUID()
    let message: LocalizedMessage
    let url: URL
    let routeID: UUID?
    let needsAttention: Bool
}

@MainActor
final class RouterModel: ObservableObject {
    static let shared = RouterModel()

    enum Recovery { case backup, unreadable }
    @Published private(set) var sourceRoutes: [SourceRoute] = []
    @Published private(set) var urlAppOverrides: [URLAppOverride] = URLAppOverride.defaults
    @Published private(set) var fallbackBrowserBundleIdentifier: String?
    @Published private(set) var fallbackBrowserName: String?
    @Published private(set) var isContextRouteDefaultHandler = false
    @Published private(set) var isSettingDefaultHandler = false
    @Published private(set) var defaultHandlerError: LocalizedMessage?
    @Published private(set) var storageError: LocalizedMessage?
    @Published private(set) var recovery: Recovery?
    @Published private(set) var routingIssue: RoutingIssue?
    @Published private(set) var routeIssues: [UUID: LocalizedMessage] = [:]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var onRoutingFailure: (() -> Void)?

    private let store = ConfigurationStore()
    private let launcher = BrowserLauncher()
    private var routingSnapshot = RoutePlanner.Snapshot()
    private struct HistoryEntry {
        let configuration: RouterConfiguration
        let actionName: String
    }
    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []

    var canEditSettings: Bool { recovery == nil }
    var undoActionName: String { undoHistory.last.map { ContextRouteLocalization.string($0.actionName) } ?? "" }
    var configuration: RouterConfiguration {
        RouterConfiguration(sourceRoutes: sourceRoutes, urlAppOverrides: urlAppOverrides,
            fallbackBrowserBundleIdentifier: fallbackBrowserBundleIdentifier, fallbackBrowserName: fallbackBrowserName)
    }

    private init() {
        reloadSettings()
        if canEditSettings { captureCurrentDefaultBrowserIfPossible() }
        refreshDefaultHandlerStatus()
    }

    func reloadSettings() {
        do {
            let loaded = try store.load()
            apply(loaded.configuration)
            recovery = loaded.recoveredFromBackup ? .backup : nil
            storageError = loaded.recoveredFromBackup
                ? LocalizedMessage(key: "Settings could not be read. A backup is available; restore it to continue editing.") : nil
        } catch {
            recovery = .unreadable
            storageError = LocalizedMessage(key: "Couldn't read settings: %@. The original file has been kept.", arguments: [error.localizedDescription])
            refreshRoutingCache()
        }
        undoHistory.removeAll()
        redoHistory.removeAll()
        updateUndoAvailability()
    }

    func restoreBackup() {
        guard recovery == .backup else { return }
        _ = commit(configuration, actionName: nil, allowRecovery: true)
    }

    func clearStorageError() { if recovery == nil { storageError = nil } }
    func dismissRoutingIssue() { routingIssue = nil }

    private static func mergeBuiltInOverrides(_ saved: [URLAppOverride]) -> [URLAppOverride] {
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var merged = URLAppOverride.defaults.map { builtIn in
            var updated = builtIn
            if let prior = savedByID[builtIn.id] { updated.isEnabled = prior.isEnabled }
            return updated
        }
        let builtInIDs = Set(URLAppOverride.defaults.map(\.id))
        merged.append(contentsOf: saved.filter { !builtInIDs.contains($0.id) })
        return merged
    }

    func refreshDefaultHandlerStatus() {
        let isDefault = ["http", "https"].allSatisfy { scheme in
            guard let sample = URL(string: "\(scheme)://example.com"),
                  let appURL = NSWorkspace.shared.urlForApplication(toOpen: sample),
                  let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return false }
            return bundleID == Bundle.main.bundleIdentifier
        }
        if isContextRouteDefaultHandler != isDefault { isContextRouteDefaultHandler = isDefault }
    }

    @discardableResult
    func add(_ route: SourceRoute) -> Bool {
        var updated = configuration
        updated.sourceRoutes.removeAll { $0.id == route.id || $0.sourceBundleIdentifier == route.sourceBundleIdentifier }
        updated.sourceRoutes.append(route)
        updated.sourceRoutes.sort { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
        return commit(updated, actionName: "Save app route")
    }

    func remove(_ route: SourceRoute) {
        var updated = configuration
        updated.sourceRoutes.removeAll { $0.id == route.id }
        _ = commit(updated, actionName: "Delete app route")
    }

    func setRouteEnabled(id: UUID, enabled: Bool) {
        var updated = configuration
        guard let index = updated.sourceRoutes.firstIndex(where: { $0.id == id }) else { return }
        updated.sourceRoutes[index].isEnabled = enabled
        _ = commit(updated, actionName: "Change app route")
    }

    func setOverrideEnabled(id: String, enabled: Bool) {
        var updated = configuration
        guard let index = updated.urlAppOverrides.firstIndex(where: { $0.id == id }) else { return }
        updated.urlAppOverrides[index].isEnabled = enabled
        _ = commit(updated, actionName: "Change app handler")
    }

    @discardableResult
    func setFallbackBrowser(_ browser: BrowserInfo?, recordUndo: Bool = true) -> Bool {
        var updated = configuration
        updated.fallbackBrowserBundleIdentifier = browser?.bundleIdentifier
        updated.fallbackBrowserName = browser?.name
        if commit(updated, actionName: recordUndo ? "Change fallback browser" : nil) {
            defaultHandlerError = nil
            return true
        }
        return false
    }

    @discardableResult
    func captureCurrentDefaultBrowserIfPossible() -> Bool {
        guard canEditSettings, fallbackBrowserBundleIdentifier == nil else { return false }
        let sample = URL(string: "https://example.com")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: sample),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let browser = BrowserCatalog.installedBrowsers().first(where: {
                  $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
              }) else { return false }
        return setFallbackBrowser(browser, recordUndo: false)
    }

    func readImport(at url: URL) throws -> RouterConfiguration { try store.read(url) }

    @discardableResult
    func importSettings(_ imported: RouterConfiguration) -> Bool {
        var merged = imported
        merged.urlAppOverrides = Self.mergeBuiltInOverrides(imported.urlAppOverrides)
        return commit(merged, actionName: canEditSettings ? "Import settings" : nil, allowRecovery: true)
    }

    func exportSettings(to url: URL) throws { try store.export(configuration, to: url) }

    private func apply(_ config: RouterConfiguration) {
        sourceRoutes = config.sourceRoutes
        urlAppOverrides = Self.mergeBuiltInOverrides(config.urlAppOverrides)
        fallbackBrowserBundleIdentifier = config.fallbackBrowserBundleIdentifier
        fallbackBrowserName = config.fallbackBrowserName
        refreshRoutingCache()
    }

    private func commit(_ updated: RouterConfiguration, actionName: String?, allowRecovery: Bool = false) -> Bool {
        guard canEditSettings || allowRecovery else { return false }
        let previous = configuration
        do {
            try store.save(updated, preserveDamagedFile: allowRecovery)
            storageError = nil
            recovery = nil
            apply(updated)
            if let actionName {
                undoHistory.append(HistoryEntry(configuration: previous, actionName: actionName))
                if undoHistory.count > 50 { undoHistory.removeFirst() }
                redoHistory.removeAll()
            }
            updateUndoAvailability()
            return true
        } catch {
            storageError = LocalizedMessage(key: "Couldn't save settings: %@", arguments: [error.localizedDescription])
            return false
        }
    }

    private func updateUndoAvailability() {
        canUndo = canEditSettings && !undoHistory.isEmpty
        canRedo = canEditSettings && !redoHistory.isEmpty
    }

    // Save first so a failed undo/redo keeps both the current settings and history intact.
    func undo() {
        guard canEditSettings, let entry = undoHistory.last else { return }
        let current = configuration
        guard commit(entry.configuration, actionName: nil) else { return }
        undoHistory.removeLast()
        redoHistory.append(HistoryEntry(configuration: current, actionName: entry.actionName))
        updateUndoAvailability()
    }

    func redo() {
        guard canEditSettings, let entry = redoHistory.last else { return }
        let current = configuration
        guard commit(entry.configuration, actionName: nil) else { return }
        redoHistory.removeLast()
        undoHistory.append(HistoryEntry(configuration: current, actionName: entry.actionName))
        updateUndoAvailability()
    }

    func refreshRoutingCache() {
        let configuration = configuration
        let startedAt = DispatchTime.now().uptimeNanoseconds
        routingSnapshot = RoutePlanner.prepare(configuration)
        RoutingDiagnostics.logCachePreparation(
            startedAt: startedAt,
            handlerCount: configuration.urlAppOverrides.filter(\.isEnabled).count,
            routeCount: configuration.sourceRoutes.count)
        routeIssues = routingSnapshot.routeIssues
    }

    func registerAsDefaultHandler() {
        guard !isSettingDefaultHandler, canEditSettings else { return }
        if fallbackBrowserBundleIdentifier == nil { _ = captureCurrentDefaultBrowserIfPossible() }
        defaultHandlerError = nil
        guard BrowserCatalog.installedBrowsers().contains(where: { $0.bundleIdentifier == fallbackBrowserBundleIdentifier }) else {
            defaultHandlerError = LocalizedMessage(key: "Choose a fallback browser first.")
            return
        }
        isSettingDefaultHandler = true
        let appURL = Bundle.main.bundleURL

        NSWorkspace.shared.setDefaultApplication(
            at: appURL,
            toOpenURLsWithScheme: "https") { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.isSettingDefaultHandler = false
                        self.defaultHandlerError = LocalizedMessage(
                            key: "macOS couldn't set the link handler: %@", arguments: [error.localizedDescription])
                        self.refreshDefaultHandlerStatus()
                        return
                    }
                    NSWorkspace.shared.setDefaultApplication(
                        at: appURL,
                        toOpenURLsWithScheme: "http") { secondError in
                            DispatchQueue.main.async {
                                self.isSettingDefaultHandler = false
                                self.refreshDefaultHandlerStatus()
                                if let secondError {
                                    self.defaultHandlerError = LocalizedMessage(
                                        key: "HTTPS is assigned; HTTP couldn't be assigned: %@",
                                        arguments: [secondError.localizedDescription])
                                }
                            }
                        }
                }
            }
    }

    func decision(for url: URL, sourceBundleIdentifier: String?) -> RouteDecision {
        RoutePlanner.decide(url, sourceBundleIdentifier: sourceBundleIdentifier, snapshot: routingSnapshot)
    }

    func route(_ url: URL, sourceBundleIdentifier: String?, trace: RoutingTrace? = nil) {
        trace?.mark("route-started", details: "source_known=\(sourceBundleIdentifier != nil)")
        let result = decision(for: url, sourceBundleIdentifier: sourceBundleIdentifier)
        trace?.mark("route-decided", details: "kind=\(result.kind.rawValue) destination=\(result.destination.diagnosticsName)")
        open(result, url: url, clearsPreviousIssue: false, trace: trace)
    }

    func retryInFallback(_ url: URL) {
        let result = RoutePlanner.decide(url, sourceBundleIdentifier: nil, snapshot: routingSnapshot.fallbackOnly)
        open(result, url: url, clearsPreviousIssue: true)
    }

    private func open(_ result: RouteDecision, url: URL, clearsPreviousIssue: Bool, trace: RoutingTrace? = nil) {
        if result.kind == .unavailable {
            trace?.mark("route-unavailable")
            reportFailure(result.explanation, url: url, routeID: result.sourceRouteID)
            return
        }
        if clearsPreviousIssue { routingIssue = nil }
        if let warning = result.warnings.first {
            routingIssue = RoutingIssue(message: warning, url: url, routeID: result.sourceRouteID, needsAttention: false)
        }
        launcher.open(result.destination, trace: trace) { [weak self] error in
            guard let self, let error else { return }
            self.reportFailure(LocalizedMessage(key: "Couldn't open the link in %@: %@", arguments: [result.targetName, error.localizedDescription]),
                url: url, routeID: result.sourceRouteID)
        }
    }

    private func reportFailure(_ message: LocalizedMessage, url: URL, routeID: UUID?) {
        routingIssue = RoutingIssue(message: message, url: url, routeID: routeID, needsAttention: true)
        onRoutingFailure?()
    }
}
