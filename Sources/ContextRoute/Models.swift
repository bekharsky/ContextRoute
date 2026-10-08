import Foundation

struct BrowserProfile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct ProfileScanResult: Sendable {
    let profiles: [BrowserProfile]
    let metadataFileExists: Bool
    let failureMessage: String?
}

struct BrowserInfo: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let appURL: URL

    var id: String { bundleIdentifier }
}

struct SourceRoute: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sourceBundleIdentifier: String
    var sourceName: String
    var browserBundleIdentifier: String
    var browserName: String
    var profileIdentifier: String?
    var profileName: String?
    var userDataDirectory: String?
    var isEnabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, sourceBundleIdentifier, sourceName, browserBundleIdentifier, browserName
        case profileIdentifier, profileName, userDataDirectory, isEnabled
    }

    init(id: UUID = UUID(), sourceBundleIdentifier: String, sourceName: String,
         browserBundleIdentifier: String, browserName: String, profileIdentifier: String?,
         profileName: String?, userDataDirectory: String?, isEnabled: Bool = true) {
        self.id = id
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceName = sourceName
        self.browserBundleIdentifier = browserBundleIdentifier
        self.browserName = browserName
        self.profileIdentifier = profileIdentifier
        self.profileName = profileName
        self.userDataDirectory = userDataDirectory
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceBundleIdentifier = try values.decode(String.self, forKey: .sourceBundleIdentifier)
        sourceName = try values.decode(String.self, forKey: .sourceName)
        browserBundleIdentifier = try values.decode(String.self, forKey: .browserBundleIdentifier)
        browserName = try values.decode(String.self, forKey: .browserName)
        profileIdentifier = try values.decodeIfPresent(String.self, forKey: .profileIdentifier)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName)
        userDataDirectory = try values.decodeIfPresent(String.self, forKey: .userDataDirectory)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct URLHostPattern: Codable, Hashable, Sendable {
    var host: String
    var includesSubdomains: Bool = false
    var pathContains: [String] = []

    func matches(_ url: URL) -> Bool {
        guard let urlHost = url.host?.lowercased() else { return false }
        let expectedHost = host.lowercased()
        let hostMatches = urlHost == expectedHost
            || (includesSubdomains && urlHost.hasSuffix(".\(expectedHost)"))
        guard hostMatches else { return false }
        return pathContains.isEmpty || pathContains.contains {
            url.path.lowercased().contains($0.lowercased())
        }
    }

    var summary: String {
        guard !pathContains.isEmpty else { return host }
        return pathContains.map { "\(host)\($0)" }.joined(separator: " · ")
    }
}

struct URLAppOverride: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hosts: [String]
    var candidateBundleIdentifiers: [String]
    var appNameHints: [String]
    var isEnabled: Bool
    // Optional so configurations written by earlier ContextRoute builds still decode.
    var hostPatterns: [URLHostPattern]?
    var pathContains: [String]?

    init(
        id: String,
        name: String,
        hosts: [String],
        candidateBundleIdentifiers: [String],
        appNameHints: [String],
        isEnabled: Bool = true,
        hostPatterns: [URLHostPattern]? = nil,
        pathContains: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.candidateBundleIdentifiers = candidateBundleIdentifiers
        self.appNameHints = appNameHints
        self.isEnabled = isEnabled
        self.hostPatterns = hostPatterns
        self.pathContains = pathContains
    }

    func matches(_ url: URL) -> Bool {
        if let hostPatterns, !hostPatterns.isEmpty {
            return hostPatterns.contains { $0.matches(url) }
        }
        guard let urlHost = url.host?.lowercased(), hosts.contains(where: {
            let expected = $0.lowercased()
            return urlHost == expected || urlHost.hasSuffix(".\(expected)")
        }) else { return false }
        guard let pathContains, !pathContains.isEmpty else { return true }
        return pathContains.contains { url.path.lowercased().contains($0.lowercased()) }
    }

    var matchSummary: String {
        if let hostPatterns, !hostPatterns.isEmpty {
            return hostPatterns.map(\.summary).joined(separator: "  ·  ")
        }
        return hosts.joined(separator: "  ·  ")
    }

    var systemSymbol: String {
        switch id {
        case "zoom": "video.fill"
        case "telegram": "paperplane.fill"
        case "slack": "number"
        case "discord": "gamecontroller.fill"
        case "teams": "person.2.fill"
        case "figma": "scribble.variable"
        case "linear": "circle.lefthalf.filled"
        case "notion": "note.text"
        case "whatsapp", "signal": "message.fill"
        case "spotify", "apple-music", "podcasts": "music.note"
        case "facetime": "video.fill"
        case "maps": "map.fill"
        case "app-store": "a.square.fill"
        case "testflight": "airplane"
        default: "app.fill"
        }
    }

    func translatedURL(_ url: URL) -> URL {
        guard id == "discord",
              let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        let webHosts: Set<String> = [
            "discord.com", "www.discord.com", "ptb.discord.com", "canary.discord.com",
            "discordapp.com", "www.discordapp.com"
        ]
        let inviteHosts: Set<String> = ["discord.gg", "www.discord.gg"]
        let path: String
        if webHosts.contains(host) {
            path = components.percentEncodedPath
        } else if inviteHosts.contains(host) {
            let inviteCode = components.percentEncodedPath
            guard inviteCode.count > 1 else { return url }
            path = "/invite" + inviteCode
        } else {
            return url
        }

        components.scheme = "discord"
        components.host = "-"
        components.port = nil
        components.user = nil
        components.password = nil
        components.percentEncodedPath = path.isEmpty ? "/" : path
        return components.url ?? url
    }

    static let defaults: [URLAppOverride] = [
        URLAppOverride(
            id: "zoom", name: "Zoom", hosts: ["zoom.us"],
            candidateBundleIdentifiers: ["us.zoom.xos"],
            appNameHints: ["Zoom Workplace", "zoom.us", "Zoom"],
            hostPatterns: [
                URLHostPattern(host: "zoom.us", includesSubdomains: true, pathContains: ["/j/", "/my/"])
            ]),
        URLAppOverride(
            id: "telegram", name: "Telegram", hosts: ["t.me"],
            candidateBundleIdentifiers: ["ru.keepcoder.Telegram"],
            appNameHints: ["Telegram"],
            hostPatterns: [URLHostPattern(host: "t.me")]),
        URLAppOverride(
            id: "slack", name: "Slack", hosts: ["slack.com"],
            candidateBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            appNameHints: ["Slack"],
            hostPatterns: [URLHostPattern(host: "slack.com", includesSubdomains: true, pathContains: ["/archives/"])]),
        URLAppOverride(
            id: "discord", name: "Discord", hosts: ["discord.com", "discord.gg", "discordapp.com"],
            candidateBundleIdentifiers: ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"],
            appNameHints: ["Discord"],
            hostPatterns: [
                URLHostPattern(host: "discord.com", includesSubdomains: true, pathContains: ["/channels/", "/invite/"]),
                URLHostPattern(host: "discordapp.com", includesSubdomains: true, pathContains: ["/channels/", "/invite/"]),
                URLHostPattern(host: "discord.gg", pathContains: ["/"])
            ]),
        URLAppOverride(
            id: "spotify", name: "Spotify", hosts: ["open.spotify.com"],
            candidateBundleIdentifiers: ["com.spotify.client"], appNameHints: ["Spotify"],
            hostPatterns: [URLHostPattern(host: "open.spotify.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "apple-music", name: "Apple Music", hosts: ["music.apple.com"],
            candidateBundleIdentifiers: ["com.apple.Music"], appNameHints: ["Music"],
            hostPatterns: [URLHostPattern(host: "music.apple.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "facetime", name: "FaceTime", hosts: ["facetime.apple.com"],
            candidateBundleIdentifiers: ["com.apple.FaceTime"], appNameHints: ["FaceTime"],
            hostPatterns: [URLHostPattern(host: "facetime.apple.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "maps", name: "Apple Maps", hosts: ["maps.apple.com"],
            candidateBundleIdentifiers: ["com.apple.Maps"], appNameHints: ["Maps", "Карты"],
            hostPatterns: [URLHostPattern(host: "maps.apple.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "teams", name: "Microsoft Teams", hosts: ["teams.microsoft.com"],
            candidateBundleIdentifiers: ["com.microsoft.teams2"], appNameHints: ["Microsoft Teams", "Teams"],
            hostPatterns: [URLHostPattern(host: "teams.microsoft.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "figma", name: "Figma", hosts: ["figma.com"],
            candidateBundleIdentifiers: ["com.figma.Desktop"], appNameHints: ["Figma"],
            hostPatterns: [URLHostPattern(host: "figma.com", includesSubdomains: true, pathContains: ["/file/", "/design/"])]),
        URLAppOverride(
            id: "linear", name: "Linear", hosts: ["linear.app"],
            candidateBundleIdentifiers: ["com.linear"], appNameHints: ["Linear"],
            hostPatterns: [URLHostPattern(host: "linear.app", includesSubdomains: true)]),
        URLAppOverride(
            id: "notion", name: "Notion", hosts: ["notion.so", "app.notion.com"],
            candidateBundleIdentifiers: ["notion.id"], appNameHints: ["Notion"],
            hostPatterns: [
                URLHostPattern(host: "notion.so", includesSubdomains: true),
                URLHostPattern(host: "app.notion.com", includesSubdomains: true)
            ]),
        URLAppOverride(
            id: "whatsapp", name: "WhatsApp", hosts: ["wa.me", "api.whatsapp.com"],
            candidateBundleIdentifiers: ["net.whatsapp.WhatsApp"], appNameHints: ["WhatsApp"],
            hostPatterns: [
                URLHostPattern(host: "wa.me"),
                URLHostPattern(host: "api.whatsapp.com", includesSubdomains: true)
            ]),
        URLAppOverride(
            id: "signal", name: "Signal", hosts: ["signal.me", "signal.group"],
            candidateBundleIdentifiers: ["org.whispersystems.signal-desktop"], appNameHints: ["Signal"],
            hostPatterns: [URLHostPattern(host: "signal.me"), URLHostPattern(host: "signal.group")]),
        URLAppOverride(
            id: "app-store", name: "App Store", hosts: ["apps.apple.com"],
            candidateBundleIdentifiers: ["com.apple.AppStore"], appNameHints: ["App Store"],
            hostPatterns: [URLHostPattern(host: "apps.apple.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "testflight", name: "TestFlight", hosts: ["testflight.apple.com"],
            candidateBundleIdentifiers: ["com.apple.TestFlight"], appNameHints: ["TestFlight"],
            hostPatterns: [URLHostPattern(host: "testflight.apple.com", includesSubdomains: true)]),
        URLAppOverride(
            id: "podcasts", name: "Apple Podcasts", hosts: ["podcasts.apple.com"],
            candidateBundleIdentifiers: ["com.apple.podcasts"], appNameHints: ["Podcasts", "Подкасты"],
            hostPatterns: [URLHostPattern(host: "podcasts.apple.com", includesSubdomains: true)])
    ]
}

struct RouterConfiguration: Codable, Sendable {
    var schemaVersion: Int? = 1
    var sourceRoutes: [SourceRoute] = []
    var urlAppOverrides: [URLAppOverride] = URLAppOverride.defaults
    var fallbackBrowserBundleIdentifier: String?
    var fallbackBrowserName: String?
}
