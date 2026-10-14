import Foundation

struct BrowserTarget: Codable, Hashable, Sendable {
    var browserBundleIdentifier: String
    var browserName: String
    var profileIdentifier: String?
    var profileName: String?
    var userDataDirectory: String?

    var displayName: String {
        guard let id = profileIdentifier else { return browserName }
        return "\(browserName) · \(profileName ?? id)"
    }
}

extension SourceRoute {
    var target: BrowserTarget {
        get {
            BrowserTarget(browserBundleIdentifier: browserBundleIdentifier, browserName: browserName,
                profileIdentifier: profileIdentifier, profileName: profileName, userDataDirectory: userDataDirectory)
        }
        set {
            browserBundleIdentifier = newValue.browserBundleIdentifier
            browserName = newValue.browserName
            profileIdentifier = newValue.profileIdentifier
            profileName = newValue.profileName
            userDataDirectory = newValue.userDataDirectory
        }
    }
}

enum WebsiteMatchKind: String, Codable, CaseIterable, Sendable {
    case domain, urlPrefix, exactURL

    var titleKey: String {
        switch self {
        case .domain: "Domain"
        case .urlPrefix: "URL starts with"
        case .exactURL: "Exact URL"
        }
    }

    var priority: Int {
        switch self {
        case .domain: 0
        case .urlPrefix: 1
        case .exactURL: 2
        }
    }
}

struct WebsitePattern: Codable, Hashable, Sendable {
    var kind: WebsiteMatchKind = .domain
    var value: String = ""
    var includesSubdomains = true

    var normalized: WebsitePattern? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace),
              let url = URL(string: input.contains("://") ? input : "https://" + input),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let host = Self.normalizedHost(url), Self.isValidHost(host) else { return nil }
        if kind == .domain {
            guard components.path.isEmpty || components.path == "/",
                  components.query == nil, components.fragment == nil, components.port == nil else { return nil }
            return WebsitePattern(kind: kind, value: host, includesSubdomains: includesSubdomains)
        }
        guard let address = Self.canonicalURL(url) else { return nil }
        return WebsitePattern(kind: kind, value: address, includesSubdomains: false)
    }

    var validationKey: String {
        kind == .domain
            ? "Enter a domain such as youtube.com. For a specific page, choose a URL condition."
            : "Enter an http or https address such as https://example.com/work/."
    }

    func matches(host: String, address: String?) -> Bool {
        switch kind {
        case .domain:
            return host == value || (includesSubdomains && host.hasSuffix("." + value))
        case .urlPrefix:
            return address?.hasPrefix(value) == true
        case .exactURL:
            return address == value
        }
    }

    func isMoreSpecific(than other: WebsitePattern) -> Bool {
        if kind.priority != other.kind.priority { return kind.priority > other.kind.priority }
        if value.count != other.value.count { return value.count > other.value.count }
        return !includesSubdomains && other.includesSubdomains
    }

    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func canonicalURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = normalizedHost(url) else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return components.url?.absoluteString
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") { return host.contains(":") }
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

struct WebsiteRoute: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var pattern: WebsitePattern
    var target: BrowserTarget
    var isEnabled = true
}
