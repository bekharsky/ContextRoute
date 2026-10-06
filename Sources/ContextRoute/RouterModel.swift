import AppKit
import Combine
import Foundation

@MainActor
final class RouterModel: ObservableObject {
    static let shared = RouterModel()

    @Published private(set) var sourceRoutes: [SourceRoute]
    @Published private(set) var urlAppOverrides: [URLAppOverride]
    @Published private(set) var fallbackBrowserBundleIdentifier: String?
    @Published private(set) var fallbackBrowserName: String?
    @Published private(set) var localizedStatus = LocalizedMessage(key: "No links have been routed yet.")
    @Published var lastRoute = ""

    var statusMessage: String { localizedStatus.text }

    private let configURL: URL
    private let logURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        configURL = support.appendingPathComponent("config.json")
        logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ContextRoute/router.log")

        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(RouterConfiguration.self, from: data) {
            sourceRoutes = config.sourceRoutes
            urlAppOverrides = Self.mergeBuiltInOverrides(config.urlAppOverrides)
            fallbackBrowserBundleIdentifier = config.fallbackBrowserBundleIdentifier
            fallbackBrowserName = config.fallbackBrowserName
        } else {
            sourceRoutes = []
            urlAppOverrides = URLAppOverride.defaults
            fallbackBrowserBundleIdentifier = nil
            fallbackBrowserName = nil
        }

        captureCurrentDefaultBrowserIfPossible()
    }

    private static func mergeBuiltInOverrides(_ saved: [URLAppOverride]) -> [URLAppOverride] {
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var merged = URLAppOverride.defaults.map { builtIn in
            var updated = builtIn
            if let prior = savedByID[builtIn.id] {
                updated.isEnabled = prior.isEnabled
            }
            return updated
        }
        let builtInIDs = Set(URLAppOverride.defaults.map(\.id))
        merged.append(contentsOf: saved.filter { !builtInIDs.contains($0.id) })
        return merged
    }

    var isContextRouteDefaultHandler: Bool {
        let sample = URL(string: "https://example.com")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: sample),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return false }
        return bundleID == Bundle.main.bundleIdentifier
    }

    func add(_ route: SourceRoute) {
        sourceRoutes.removeAll { $0.sourceBundleIdentifier == route.sourceBundleIdentifier }
        sourceRoutes.append(route)
        sourceRoutes.sort { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
        persist()
        setStatus("Rule saved for %@.", arguments: [route.sourceName])
    }

    func remove(_ route: SourceRoute) {
        sourceRoutes.removeAll { $0.id == route.id }
        persist()
    }

    func setOverrideEnabled(id: String, enabled: Bool) {
        guard let index = urlAppOverrides.firstIndex(where: { $0.id == id }) else { return }
        urlAppOverrides[index].isEnabled = enabled
        persist()
    }

    func setFallbackBrowser(_ browser: BrowserInfo?) {
        fallbackBrowserBundleIdentifier = browser?.bundleIdentifier
        fallbackBrowserName = browser?.name
        persist()
        if let browser {
            setStatus("Fallback browser: %@.", arguments: [browser.name])
        } else {
            setStatus("No fallback browser selected.")
        }
    }

    @discardableResult
    func captureCurrentDefaultBrowserIfPossible() -> Bool {
        let sample = URL(string: "https://example.com")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: sample),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return false }
        guard let browser = BrowserCatalog.installedBrowsers().first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else {
            setStatus("The current link handler isn't recognized as a browser. Choose a fallback browser manually.")
            return false
        }

        fallbackBrowserBundleIdentifier = browser.bundleIdentifier
        fallbackBrowserName = browser.name
        persist()
        return true
    }

    func registerAsDefaultHandler() {
        _ = captureCurrentDefaultBrowserIfPossible()
        guard fallbackBrowserBundleIdentifier != nil else {
            setStatus("Choose a fallback browser first.")
            return
        }
        let appURL = Bundle.main.bundleURL

        NSWorkspace.shared.setDefaultApplication(
            at: appURL,
            toOpenURLsWithScheme: "https") { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.setStatus("macOS couldn't set the link handler: %@", arguments: [error.localizedDescription])
                        return
                    }
                    NSWorkspace.shared.setDefaultApplication(
                        at: appURL,
                        toOpenURLsWithScheme: "http") { secondError in
                            DispatchQueue.main.async {
                                if let secondError {
                                    self.setStatus("HTTPS is assigned; HTTP couldn't be assigned: %@", arguments: [secondError.localizedDescription])
                                } else {
                                    self.setStatus("ContextRoute is now the default handler.")
                                }
                            }
                        }
                }
            }
    }

    func route(_ url: URL, sourceBundleIdentifier: String?) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            openFallback(url, reason: ContextRouteLocalization.string("Unsupported link type"))
            return
        }

        if let override = urlAppOverrides.first(where: { $0.isEnabled && $0.matches(url) }) {
            if let appURL = BrowserCatalog.findApplication(for: override) {
                let targetName = override.name
                lastRoute = "\(url.host ?? override.name) → \(targetName)"
                setStatus("Sent %@ to %@.", arguments: [url.host ?? "link", targetName])
                log("URL override \(url.host ?? "") → \(targetName)")
                let targetURL = override.translatedURL(url)
                open(targetURL, inApplicationAt: appURL, fallbackOnError: true, reason: "URL override: \(targetName)")
                return
            } else {
                log("URL override target missing: \(override.name) | \(safeURLLabel(url))")
                setStatus("%@ isn't installed; using the normal route for this link.", arguments: [override.name])
            }
        }

        if let sourceBundleIdentifier,
           let route = sourceRoutes.first(where: { $0.sourceBundleIdentifier == sourceBundleIdentifier }),
           let appURL = BrowserCatalog.applicationURL(bundleIdentifier: route.browserBundleIdentifier) {
            let target = route.profileName.map { "\(route.browserName) · \($0)" } ?? route.browserName
            lastRoute = "\(route.sourceName) → \(target)"
            setStatus("Last link: %@", arguments: [lastRoute])
            log("\(lastRoute) | \(safeURLLabel(url))")
            open(url, in: route, appURL: appURL)
            return
        }

        let sourceName = sourceBundleIdentifier.map(displayName(forBundleIdentifier:)) ?? "Unknown app"
        lastRoute = "\(sourceName) → \(fallbackBrowserName ?? "Fallback browser")"
        setStatus("No rule for %@; sending to the fallback browser.", arguments: [sourceName])
        log("\(lastRoute) | \(safeURLLabel(url))")
        openFallback(url, reason: ContextRouteLocalization.string("No source app rule"))
    }

    private func open(_ url: URL, in route: SourceRoute, appURL: URL) {
        guard let profileID = route.profileIdentifier else {
            open(url, inApplicationAt: appURL, fallbackOnError: true, reason: route.browserName)
            return
        }

        let browser = BrowserInfo(
            bundleIdentifier: route.browserBundleIdentifier,
            name: route.browserName,
            appURL: appURL)
        guard var arguments = BrowserCatalog.profileLaunchArguments(
            browser: browser,
            profileIdentifier: profileID,
            userDataDirectory: route.userDataDirectory),
              let executableURL = BrowserCatalog.executableURL(for: appURL) else {
            open(url, inApplicationAt: appURL, fallbackOnError: true, reason: route.browserName)
            return
        }

        arguments.append(url.absoluteString)
        log("Launching \(route.browserName) with profile ID \(profileID)")
        launchProcess(
            executableURL: executableURL,
            arguments: arguments,
            url: url,
            reason: ContextRouteLocalization.format(
                "Profile %@", arguments: [route.profileName ?? profileID]))
    }

    private func launchProcess(executableURL: URL, arguments: [String], url: URL, reason: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            setStatus("Couldn't launch the selected profile; using the fallback browser.")
            log("\(reason) launch failed: \(error.localizedDescription)")
            openFallback(url, reason: ContextRouteLocalization.string("Profile launch failed"))
        }
    }

    private func open(_ url: URL, inApplicationAt appURL: URL, fallbackOnError: Bool, reason: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.log("Open \(reason) failed: \(error.localizedDescription)")
                if fallbackOnError {
                    let fallbackReason = ContextRouteLocalization.format(
                        "Routing failed: %@", arguments: [reason])
                    self?.openFallback(url, reason: fallbackReason)
                }
            }
        }
    }

    private func openFallback(_ url: URL, reason: String) {
        guard let bundleID = fallbackBrowserBundleIdentifier,
              let appURL = BrowserCatalog.applicationURL(bundleIdentifier: bundleID) else {
            setStatus("Select a fallback browser in ContextRoute Settings.")
            log("No fallback browser for \(safeURLLabel(url)) (\(reason))")
            return
        }
        lastRoute = "\(reason) → \(fallbackBrowserName ?? "Browser")"
        open(url, inApplicationAt: appURL, fallbackOnError: false, reason: lastRoute)
    }

    private func safeURLLabel(_ url: URL) -> String {
        if let host = url.host { return "\(url.scheme ?? "URL")://\(host)" }
        return url.scheme ?? "URL"
    }

    private func displayName(forBundleIdentifier bundleID: String) -> String {
        if let appURL = BrowserCatalog.applicationURL(bundleIdentifier: bundleID) {
            return (Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func persist() {
        let configuration = RouterConfiguration(
            sourceRoutes: sourceRoutes,
            urlAppOverrides: urlAppOverrides,
            fallbackBrowserBundleIdentifier: fallbackBrowserBundleIdentifier,
            fallbackBrowserName: fallbackBrowserName)
        do {
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: configURL, options: .atomic)
        } catch {
            setStatus("Couldn't save settings: %@", arguments: [error.localizedDescription])
        }
    }

    private func setStatus(_ key: String, arguments: [String] = []) {
        localizedStatus = LocalizedMessage(key: key, arguments: arguments)
    }

    private func log(_ message: String) {
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
