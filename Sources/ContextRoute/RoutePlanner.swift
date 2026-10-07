import AppKit

enum RouteDestination {
    case application(appURL: URL, url: URL)
    case profile(browser: BrowserInfo, route: SourceRoute, url: URL)
    case unavailable
}

struct RouteDecision {
    enum Kind { case handler, appRoute, fallback, unavailable }
    var kind: Kind
    var destination: RouteDestination
    var targetName: String
    var explanation: LocalizedMessage
    var warnings: [LocalizedMessage] = []
    var sourceRouteID: UUID?

    var kindName: String {
        let key = switch kind {
        case .handler: "Open in apps"
        case .appRoute: "App route"
        case .fallback: "Fallback browser"
        case .unavailable: "Unavailable"
        }
        return ContextRouteLocalization.string(key)
    }
}

/// Shared by actual routing and the route checker. Selecting a route has no side effects.
enum RoutePlanner {
    static func decide(_ url: URL, sourceBundleIdentifier: String?, configuration: RouterConfiguration) -> RouteDecision {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return RouteDecision(kind: .unavailable, destination: .unavailable, targetName: "",
                explanation: LocalizedMessage(key: "Enter a complete http or https link."))
        }
        var warnings: [LocalizedMessage] = []
        if let handler = configuration.urlAppOverrides.first(where: { $0.isEnabled && $0.matches(url) }) {
            if let appURL = BrowserCatalog.findApplication(for: handler) {
                return RouteDecision(kind: .handler,
                    destination: .application(appURL: appURL, url: handler.translatedURL(url)), targetName: handler.name,
                    explanation: LocalizedMessage(key: "This link matches %@. Open in apps takes priority over app routes.", arguments: [handler.name]))
            }
            warnings.append(LocalizedMessage(key: "%@ isn't installed; using the normal route for this link.", arguments: [handler.name]))
        }

        let route = configuration.sourceRoutes.first { $0.sourceBundleIdentifier == sourceBundleIdentifier }
        if let route, route.isEnabled {
            if let issue = issue(for: route) {
                warnings.append(issue)
            } else if let appURL = BrowserCatalog.applicationURL(bundleIdentifier: route.browserBundleIdentifier) {
                let browser = BrowserInfo(bundleIdentifier: route.browserBundleIdentifier, name: route.browserName, appURL: appURL)
                let destination: RouteDestination = route.profileIdentifier == nil
                    ? .application(appURL: appURL, url: url)
                    : .profile(browser: browser, route: route, url: url)
                return RouteDecision(kind: .appRoute, destination: destination,
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
        guard let bundleID = configuration.fallbackBrowserBundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let appURL = BrowserCatalog.applicationURL(bundleIdentifier: bundleID),
              BrowserCatalog.installedBrowsers().contains(where: { $0.bundleIdentifier == bundleID }) else {
            return RouteDecision(kind: .unavailable, destination: .unavailable, targetName: "",
                explanation: LocalizedMessage(key: "Choose an installed fallback browser in Settings."),
                warnings: warnings, sourceRouteID: route?.id)
        }
        return RouteDecision(kind: .fallback, destination: .application(appURL: appURL, url: url),
            targetName: configuration.fallbackBrowserName ?? appURL.deletingPathExtension().lastPathComponent,
            explanation: explanation, warnings: warnings, sourceRouteID: route?.id)
    }

    static func issue(for route: SourceRoute) -> LocalizedMessage? {
        guard route.browserBundleIdentifier != Bundle.main.bundleIdentifier,
              let appURL = BrowserCatalog.applicationURL(bundleIdentifier: route.browserBundleIdentifier),
              FileManager.default.fileExists(atPath: appURL.path) else {
            return LocalizedMessage(key: "%@ is not installed. Choose another browser.", arguments: [route.browserName])
        }
        guard let profileID = route.profileIdentifier else { return nil }
        let browser = BrowserInfo(bundleIdentifier: route.browserBundleIdentifier, name: route.browserName, appURL: appURL)
        guard BrowserCatalog.supportsProfiles(for: browser) else {
            return LocalizedMessage(key: "This browser no longer supports the selected profile.")
        }
        guard BrowserCatalog.profileDirectoryExists(for: browser, profileIdentifier: profileID, userDataDirectory: route.userDataDirectory) else {
            return LocalizedMessage(key: "The selected profile is missing or inaccessible. Choose it again.")
        }
        return nil
    }
}
