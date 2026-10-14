import AppKit

enum RouteDestination: Sendable {
    case application(appURL: URL, url: URL)
    case profile(appURL: URL, bundleIdentifier: String, executableURL: URL, arguments: [String], url: URL)
    case unavailable

    var diagnosticsName: String {
        switch self {
        case .application: "application"
        case .profile: "profile"
        case .unavailable: "unavailable"
        }
    }
}

struct RouteDecision: Sendable {
    enum Kind: String, Sendable { case handler, websiteRoute, appRoute, fallback, unavailable }
    var kind: Kind
    var destination: RouteDestination
    var targetName: String
    var explanation: LocalizedMessage
    var warnings: [LocalizedMessage] = []
    var sourceRouteID: UUID?
    var websiteRouteID: UUID?

    var routeID: UUID? { websiteRouteID ?? sourceRouteID }

    var kindName: String {
        let key = switch kind {
        case .handler: "Open in apps"
        case .websiteRoute: "Website route"
        case .appRoute: "App route"
        case .fallback: "Fallback browser"
        case .unavailable: "Unavailable"
        }
        return ContextRouteLocalization.string(key)
    }
}

/// Resolves installed applications and profiles when settings load or change.
/// Actual routing and the route checker only read the prepared snapshot.
enum RoutePlanner {
    struct Snapshot: Sendable {
        fileprivate var handlers: [PreparedHandler] = []
        fileprivate var sourceRoutes: [String: PreparedRoute] = [:]
        fileprivate var websiteRoutes: [PreparedWebsiteRoute] = []
        fileprivate var needsAddressMatching = false
        fileprivate var fallback: Target?
        fileprivate var fallbackName = ""
        var fallbackIssue: LocalizedMessage?

        init() {}

        var routeIssues: [UUID: LocalizedMessage] {
            let appIssues = sourceRoutes.values.compactMap { prepared -> (UUID, LocalizedMessage)? in
                if case let .unavailable(issue) = prepared.availability { return (prepared.route.id, issue) }
                return nil
            }
            let websiteIssues = websiteRoutes.compactMap { prepared -> (UUID, LocalizedMessage)? in
                if case let .unavailable(issue) = prepared.availability { return (prepared.route.id, issue) }
                return nil
            }
            return Dictionary(appIssues + websiteIssues, uniquingKeysWith: { first, _ in first })
        }

        var fallbackOnly: Snapshot {
            var result = self
            result.handlers = []
            result.sourceRoutes = [:]
            result.websiteRoutes = []
            result.needsAddressMatching = false
            return result
        }
    }

    fileprivate enum Target: Sendable {
        case application(URL)
        case profile(appURL: URL, bundleIdentifier: String, executableURL: URL, arguments: [String])

        func destination(for url: URL) -> RouteDestination {
            switch self {
            case let .application(appURL): .application(appURL: appURL, url: url)
            case let .profile(appURL, bundleIdentifier, executableURL, arguments):
                .profile(appURL: appURL, bundleIdentifier: bundleIdentifier,
                    executableURL: executableURL, arguments: arguments, url: url)
            }
        }
    }

    fileprivate enum Availability: Sendable {
        case available(Target)
        case unavailable(LocalizedMessage)
    }

    fileprivate struct PreparedRoute: Sendable {
        let route: SourceRoute
        let availability: Availability
    }

    fileprivate struct PreparedHandler: Sendable {
        let rule: URLAppOverride
        let appURL: URL?
    }

    fileprivate struct PreparedWebsiteRoute: Sendable {
        let route: WebsiteRoute
        let pattern: WebsitePattern?
        let availability: Availability
    }

    static func prepare(_ configuration: RouterConfiguration) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.handlers = configuration.urlAppOverrides.filter(\.isEnabled).map {
            PreparedHandler(rule: $0, appURL: BrowserCatalog.findApplication(for: $0))
        }
        for route in configuration.sourceRoutes where snapshot.sourceRoutes[route.sourceBundleIdentifier] == nil {
            snapshot.sourceRoutes[route.sourceBundleIdentifier] = PreparedRoute(route: route, availability: prepare(route.target))
        }
        snapshot.websiteRoutes = configuration.websiteRoutes.map { route in
            let pattern = route.pattern.normalized
            return PreparedWebsiteRoute(route: route, pattern: pattern,
                availability: pattern == nil
                    ? .unavailable(LocalizedMessage(key: route.pattern.validationKey)) : prepare(route.target))
        }.sorted { left, right in
            (left.pattern ?? left.route.pattern).isMoreSpecific(than: right.pattern ?? right.route.pattern)
        }
        snapshot.needsAddressMatching = snapshot.websiteRoutes.contains { $0.route.isEnabled && $0.pattern?.kind != .domain }
        if let target = configuration.fallbackTarget {
            snapshot.fallbackName = target.displayName
            switch prepare(target) {
            case let .available(destination): snapshot.fallback = destination
            case let .unavailable(issue): snapshot.fallbackIssue = issue
            }
        }
        return snapshot
    }

    static func decide(_ url: URL, sourceBundleIdentifier: String?, snapshot: Snapshot) -> RouteDecision {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return RouteDecision(kind: .unavailable, destination: .unavailable, targetName: "",
                explanation: LocalizedMessage(key: "Enter a complete http or https link."))
        }
        var warnings: [LocalizedMessage] = []
        if !snapshot.websiteRoutes.isEmpty, let host = WebsitePattern.normalizedHost(url) {
            let address = snapshot.needsAddressMatching ? WebsitePattern.canonicalURL(url) : nil
            if let matching = snapshot.websiteRoutes.first(where: {
                $0.route.isEnabled && $0.pattern?.matches(host: host, address: address) == true
            }) {
                switch matching.availability {
                case let .available(target):
                    return RouteDecision(kind: .websiteRoute, destination: target.destination(for: url),
                        targetName: matching.route.target.displayName,
                        explanation: LocalizedMessage(key: "Matches the website rule for %@.", arguments: [matching.route.pattern.value]),
                        websiteRouteID: matching.route.id)
                case let .unavailable(issue):
                    return RouteDecision(kind: .unavailable, destination: .unavailable,
                        targetName: matching.route.target.displayName, explanation: issue, websiteRouteID: matching.route.id)
                }
            }
        }
        if let handler = snapshot.handlers.first(where: { $0.rule.matches(url) }) {
            if let appURL = handler.appURL {
                return RouteDecision(kind: .handler,
                    destination: .application(appURL: appURL, url: handler.rule.translatedURL(url)), targetName: handler.rule.name,
                    explanation: LocalizedMessage(key: "This link matches %@. Open in apps takes priority over app routes.", arguments: [handler.rule.name]),
                    warnings: warnings)
            }
            warnings.append(LocalizedMessage(key: "%@ isn't installed; using the normal route for this link.", arguments: [handler.rule.name]))
        }

        let prepared = sourceBundleIdentifier.flatMap { snapshot.sourceRoutes[$0] }
        let route = prepared?.route
        if let prepared, prepared.route.isEnabled {
            let route = prepared.route
            switch prepared.availability {
            case let .unavailable(issue):
                warnings.append(issue)
            case let .available(target):
                return RouteDecision(kind: .appRoute, destination: target.destination(for: url),
                    targetName: route.profileName.map { "\(route.browserName) · \($0)" } ?? route.browserName,
                    explanation: LocalizedMessage(key: "Uses the app route for %@.", arguments: [route.sourceName]),
                    warnings: warnings, sourceRouteID: route.id)
            }
        }

        let explanation: LocalizedMessage
        if let route, !route.isEnabled {
            explanation = LocalizedMessage(key: "The app route for %@ is turned off.", arguments: [route.sourceName])
        } else {
            explanation = LocalizedMessage(key: "No available app route matches this link.")
        }
        guard let fallback = snapshot.fallback else {
            return RouteDecision(kind: .unavailable, destination: .unavailable, targetName: "",
                explanation: snapshot.fallbackIssue ?? LocalizedMessage(key: "Choose an installed fallback browser in Settings."),
                warnings: warnings)
        }
        return RouteDecision(kind: .fallback, destination: fallback.destination(for: url),
            targetName: snapshot.fallbackName,
            explanation: explanation, warnings: warnings, sourceRouteID: route?.id)
    }

    private static func prepare(_ route: BrowserTarget) -> Availability {
        guard route.browserBundleIdentifier != Bundle.main.bundleIdentifier,
              let browser = BrowserCatalog.browser(bundleIdentifier: route.browserBundleIdentifier),
              FileManager.default.fileExists(atPath: browser.appURL.path) else {
            return .unavailable(LocalizedMessage(key: "%@ is not installed. Choose another browser.", arguments: [route.browserName]))
        }
        let appURL = browser.appURL
        guard let profileID = route.profileIdentifier else { return .available(.application(appURL)) }
        guard BrowserCatalog.supportsProfiles(for: browser) else {
            return .unavailable(LocalizedMessage(key: "This browser no longer supports the selected profile."))
        }
        guard BrowserCatalog.profileDirectoryExists(for: browser, profileIdentifier: profileID, userDataDirectory: route.userDataDirectory) else {
            return .unavailable(LocalizedMessage(key: "The selected profile is missing or inaccessible. Choose it again."))
        }
        guard let executableURL = BrowserCatalog.executableURL(for: appURL),
              let arguments = BrowserCatalog.profileLaunchArguments(browser: browser,
                profileIdentifier: profileID, userDataDirectory: route.userDataDirectory) else {
            return .unavailable(LocalizedMessage(key: "The selected profile cannot be opened."))
        }
        return .available(.profile(appURL: appURL, bundleIdentifier: route.browserBundleIdentifier,
            executableURL: executableURL, arguments: arguments))
    }
}
