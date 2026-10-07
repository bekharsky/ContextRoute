import AppKit
import Foundation

enum BrowserCatalog {
    private enum ProfileEngine: Equatable {
        case chromium
        case firefox
    }

    private struct ProfileConfiguration {
        let engine: ProfileEngine
        let applicationSupportPath: String
    }

    // Profile locations mirror Yojam's BrowserProfileCatalog.
    private static let profileConfigurations: [String: ProfileConfiguration] = [
        "com.brave.browser": .init(engine: .chromium, applicationSupportPath: "BraveSoftware/Brave-Browser"),
        "com.brave.browser.beta": .init(engine: .chromium, applicationSupportPath: "BraveSoftware/Brave-Browser-Beta"),
        "com.brave.browser.dev": .init(engine: .chromium, applicationSupportPath: "BraveSoftware/Brave-Browser-Dev"),
        "com.google.chrome": .init(engine: .chromium, applicationSupportPath: "Google/Chrome"),
        "com.google.chrome.beta": .init(engine: .chromium, applicationSupportPath: "Google/Chrome Beta"),
        "com.google.chrome.canary": .init(engine: .chromium, applicationSupportPath: "Google/Chrome Canary"),
        "org.chromium.chromium": .init(engine: .chromium, applicationSupportPath: "Chromium"),
        "com.microsoft.edgemac": .init(engine: .chromium, applicationSupportPath: "Microsoft Edge"),
        "com.microsoft.edgemac.beta": .init(engine: .chromium, applicationSupportPath: "Microsoft Edge Beta"),
        "com.vivaldi.vivaldi": .init(engine: .chromium, applicationSupportPath: "Vivaldi"),
        "com.bookry.wavebox": .init(engine: .chromium, applicationSupportPath: "WaveboxApp"),
        "net.imput.helium": .init(engine: .chromium, applicationSupportPath: "net.imput.helium"),
        "ai.perplexity.comet": .init(engine: .chromium, applicationSupportPath: "Comet"),
        "ru.yandex.desktop.yandex-browser": .init(engine: .chromium, applicationSupportPath: "Yandex/YandexBrowser"),
        "com.operasoftware.opera": .init(engine: .chromium, applicationSupportPath: "com.operasoftware.Opera"),
        "com.operasoftware.operagx": .init(engine: .chromium, applicationSupportPath: "com.operasoftware.OperaGX"),
        "org.mozilla.firefox": .init(engine: .firefox, applicationSupportPath: "Firefox"),
        "org.mozilla.firefoxdeveloperedition": .init(engine: .firefox, applicationSupportPath: "Firefox"),
        "org.mozilla.nightly": .init(engine: .firefox, applicationSupportPath: "Firefox Nightly"),
        "app.zen-browser.zen": .init(engine: .firefox, applicationSupportPath: "zen")
    ]

    static func installedBrowsers() -> [BrowserInfo] {
        let sampleURL = URL(string: "https://example.com")!
        var urls = NSWorkspace.shared.urlsForApplications(toOpen: sampleURL)
        urls.append(contentsOf: topLevelApplicationURLs())

        var seen = Set<String>()
        return urls.compactMap { url -> BrowserInfo? in
            guard url.pathExtension == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  seen.insert(bundleID.lowercased()).inserted else { return nil }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            guard isBrowser(name: name, bundleIdentifier: bundleID) else { return nil }
            return BrowserInfo(bundleIdentifier: bundleID, name: name, appURL: url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func profiles(for browser: BrowserInfo, userDataDirectory: String? = nil) -> [BrowserProfile] {
        profileScan(for: browser, userDataDirectory: userDataDirectory).profiles
    }

    static func profileScan(for browser: BrowserInfo, userDataDirectory: String? = nil) -> ProfileScanResult {
        guard let configuration = configuration(for: browser) else {
            return ProfileScanResult(
                profiles: [],
                metadataFileExists: false,
                failureMessage: ContextRouteLocalization.string("ContextRoute can't read profiles for this browser."))
        }

        let root = profileRoot(for: configuration, userDataDirectory: userDataDirectory)
        switch configuration.engine {
        case .chromium:
            return readChromiumProfiles(in: root)
        case .firefox:
            return readFirefoxProfiles(in: root)
        }
    }

    /// Returns the standard data directory for the selected browser from Yojam's catalog.
    /// The folder picker and profile scanner start there instead of reusing the last folder.
    static func defaultUserDataDirectory(for browser: BrowserInfo) -> String? {
        guard let configuration = configuration(for: browser) else { return nil }
        let conventionalRoot = applicationSupportDirectory
            .appendingPathComponent(configuration.applicationSupportPath, isDirectory: true)
        return conventionalRoot.standardizedFileURL.path
    }

    static func supportsProfiles(for browser: BrowserInfo) -> Bool {
        configuration(for: browser) != nil
    }

    static func supportsUserDataDirectory(for browser: BrowserInfo) -> Bool {
        configuration(for: browser)?.engine == .chromium
    }

    static func metadataFileName(for browser: BrowserInfo) -> String? {
        guard let configuration = configuration(for: browser) else { return nil }
        return metadataFileName(for: configuration)
    }

    static func executableURL(for appURL: URL) -> URL? {
        Bundle(url: appURL)?.executableURL
    }

    static func profileDirectoryExists(for browser: BrowserInfo, profileIdentifier: String, userDataDirectory: String?) -> Bool {
        guard let configuration = configuration(for: browser) else { return false }
        let directory: URL
        switch configuration.engine {
        case .chromium:
            guard !profileIdentifier.isEmpty, !profileIdentifier.contains("/"), profileIdentifier != ".", profileIdentifier != ".." else { return false }
            directory = profileRoot(for: configuration, userDataDirectory: userDataDirectory)
                .appendingPathComponent(profileIdentifier, isDirectory: true)
        case .firefox:
            let path = expandHome(profileIdentifier)
            guard path.hasPrefix("/") else { return false }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func profileLaunchArguments(
        browser: BrowserInfo,
        profileIdentifier: String,
        userDataDirectory: String?
    ) -> [String]? {
        guard let configuration = configuration(for: browser) else { return nil }
        switch configuration.engine {
        case .chromium:
            var arguments: [String] = []
            if let userDataDirectory, !userDataDirectory.isEmpty {
                arguments.append("--user-data-dir=\(expandHome(userDataDirectory))")
            }
            arguments.append("--profile-directory=\(profileIdentifier)")
            return arguments
        case .firefox:
            return ["--profile", expandHome(profileIdentifier), "--new-instance"]
        }
    }

    static func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func findApplication(for override: URLAppOverride) -> URL? {
        for bundleID in override.candidateBundleIdentifiers {
            if bundleID != Bundle.main.bundleIdentifier,
               let url = applicationURL(bundleIdentifier: bundleID),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }

        let hints = override.appNameHints.map { $0.lowercased() }.filter { !$0.isEmpty }
        return topLevelApplicationURLs().first { url in
            let bundle = Bundle(url: url)
            guard bundle?.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return hints.contains { bundleName.lowercased().contains($0) }
        }
    }

    static func expandHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        if path.hasPrefix("$HOME/") { return home + String(path.dropFirst(5)) }
        return path
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func configuration(for browser: BrowserInfo) -> ProfileConfiguration? {
        profileConfigurations[browser.bundleIdentifier.lowercased()]
    }

    private static func profileRoot(
        for configuration: ProfileConfiguration,
        userDataDirectory: String?
    ) -> URL {
        if let userDataDirectory,
           !userDataDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandHome(userDataDirectory), isDirectory: true)
        }
        return applicationSupportDirectory
            .appendingPathComponent(configuration.applicationSupportPath, isDirectory: true)
    }

    private static func metadataFileName(for configuration: ProfileConfiguration) -> String {
        switch configuration.engine {
        case .chromium: "Local State"
        case .firefox: "profiles.ini"
        }
    }

    private static func readChromiumProfiles(in root: URL) -> ProfileScanResult {
        let stateURL = root.appendingPathComponent("Local State")
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return ProfileScanResult(
                profiles: [], metadataFileExists: false,
                failureMessage: ContextRouteLocalization.string("Local State was not found in the selected folder."))
        }

        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            return ProfileScanResult(
                profiles: [], metadataFileExists: true,
                failureMessage: ContextRouteLocalization.format(
                    "Couldn't read Local State: %@", arguments: [error.localizedDescription]))
        }

        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Chromium writes Local State while the browser is running; retry once in case
            // the file was observed during an atomic update.
            Thread.sleep(forTimeInterval: 0.1)
            guard let retryData = try? Data(contentsOf: stateURL),
                  let retryObject = try? JSONSerialization.jsonObject(with: retryData) else {
                return ProfileScanResult(
                    profiles: [], metadataFileExists: true,
                    failureMessage: ContextRouteLocalization.string("Local State couldn't be parsed as JSON."))
            }
            return chromiumProfiles(from: retryObject)
        }
        return chromiumProfiles(from: rootObject)
    }

    private static func chromiumProfiles(from rootObject: Any) -> ProfileScanResult {
        guard let json = rootObject as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return ProfileScanResult(
                profiles: [], metadataFileExists: true,
                failureMessage: ContextRouteLocalization.string("Local State doesn't contain profile.info_cache."))
        }

        let profiles = cache.compactMap { directory, rawMetadata -> BrowserProfile? in
            guard let metadata = rawMetadata as? [String: Any] else { return nil }
            let displayName = (metadata["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? (metadata["gaia_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? directory
            let email = metadata["user_name"] as? String
            let label = email.map { "\(displayName) · \($0)" } ?? displayName
            return BrowserProfile(id: directory, name: label)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ProfileScanResult(profiles: profiles, metadataFileExists: true, failureMessage: nil)
    }

    private static func readFirefoxProfiles(in root: URL) -> ProfileScanResult {
        let profilesURL = root.appendingPathComponent("profiles.ini")
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            return ProfileScanResult(
                profiles: [], metadataFileExists: false,
                failureMessage: ContextRouteLocalization.string("profiles.ini was not found in the selected folder."))
        }
        guard let content = try? String(contentsOf: profilesURL, encoding: .utf8) else {
            return ProfileScanResult(
                profiles: [], metadataFileExists: true,
                failureMessage: ContextRouteLocalization.string("Couldn't read profiles.ini."))
        }

        var sections: [(name: String, values: [String: String])] = []
        var sectionName: String?
        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";") && !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let sectionName { sections.append((sectionName, values)) }
                sectionName = String(trimmed.dropFirst().dropLast())
                values = [:]
            } else if let separator = trimmed.firstIndex(of: "=") {
                values[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
            }
        }
        if let sectionName { sections.append((sectionName, values)) }

        let defaultPaths = Set(sections.compactMap { section -> String? in
            guard section.name.hasPrefix("Install") else { return nil }
            return section.values["Default"]
        })
        let profiles = sections.compactMap { section -> (profile: BrowserProfile, isDefault: Bool)? in
            guard section.name.hasPrefix("Profile"),
                  let name = section.values["Name"],
                  let path = section.values["Path"], !name.isEmpty else { return nil }
            let isRelative = section.values["IsRelative"] != "0"
            let profileURL = isRelative
                ? URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
                : URL(fileURLWithPath: path).standardizedFileURL
            let isDefault = defaultPaths.contains(path) || section.values["Default"] == "1"
            return (BrowserProfile(id: profileURL.path, name: name), isDefault)
        }
        .sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }

        guard !profiles.isEmpty else {
            return ProfileScanResult(
                profiles: [], metadataFileExists: true,
                failureMessage: ContextRouteLocalization.string("No profiles were found in profiles.ini."))
        }
        // Keep Firefox's default profile first in the picker, like Yojam, then sort the rest.
        let ordered = profiles.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
        }.map(\.profile)
        return ProfileScanResult(profiles: ordered, metadataFileExists: true, failureMessage: nil)
    }

    private static func isBrowser(name: String, bundleIdentifier: String) -> Bool {
        let lower = (name + " " + bundleIdentifier).lowercased()
        return ["safari", "chrome", "firefox", "brave", "edge", "vivaldi", "opera", "arc", "orion", "zen",
                "wavebox", "helium", "comet", "yandex"]
            .contains(where: lower.contains)
    }

    private static func topLevelApplicationURLs() -> [URL] {
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let roots = [URL(fileURLWithPath: "/Applications"), homeApps]
        return roots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
        }
        .filter { $0.pathExtension == "app" }
    }
}
