import AppKit

enum RouteDestination: Sendable {
    case application(appURL: URL, url: URL)
    case profile(browser: BrowserInfo, route: SourceRoute, url: URL)
    case unavailable
}

struct RouteDecision: Sendable {
    enum Kind: Sendable { case handler, appRoute, fallback, unavailable }
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
            switch availability(for: route) {
            case let .unavailable(issue):
                warnings.append(issue)
            case let .available(browser):
                let destination: RouteDestination = route.profileIdentifier == nil
                    ? .application(appURL: browser.appURL, url: url)
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
              let browser = BrowserCatalog.browser(bundleIdentifier: bundleID) else {
            return RouteDecision(kind: .unavailable, destination: .unavailable, targetName: "",
                explanation: LocalizedMessage(key: "Choose an installed fallback browser in Settings."),
                warnings: warnings, sourceRouteID: route?.id)
        }
        return RouteDecision(kind: .fallback, destination: .application(appURL: browser.appURL, url: url),
            targetName: configuration.fallbackBrowserName ?? browser.name,
            explanation: explanation, warnings: warnings, sourceRouteID: route?.id)
    }

    static func issue(for route: SourceRoute) -> LocalizedMessage? {
        switch availability(for: route) {
        case .available: nil
        case let .unavailable(issue): issue
        }
    }

    private enum Availability {
        case available(BrowserInfo)
        case unavailable(LocalizedMessage)
    }

    private static func availability(for route: SourceRoute) -> Availability {
        guard route.browserBundleIdentifier != Bundle.main.bundleIdentifier,
              let appURL = BrowserCatalog.applicationURL(bundleIdentifier: route.browserBundleIdentifier),
              FileManager.default.fileExists(atPath: appURL.path) else {
            return .unavailable(LocalizedMessage(key: "%@ is not installed. Choose another browser.", arguments: [route.browserName]))
        }
        let browser = BrowserInfo(bundleIdentifier: route.browserBundleIdentifier, name: route.browserName, appURL: appURL)
        guard let profileID = route.profileIdentifier else { return .available(browser) }
        guard BrowserCatalog.supportsProfiles(for: browser) else {
            return .unavailable(LocalizedMessage(key: "This browser no longer supports the selected profile."))
        }
        guard BrowserCatalog.profileDirectoryExists(for: browser, profileIdentifier: profileID, userDataDirectory: route.userDataDirectory) else {
            return .unavailable(LocalizedMessage(key: "The selected profile is missing or inaccessible. Choose it again."))
        }
        return .available(browser)
    }
}
