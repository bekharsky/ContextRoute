import AppKit
import Darwin
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class LaunchRecording {
    var errors: [Error] = []
}

@main
@MainActor
struct RoutingChecks {
    private static var assertions = 0

    static func main() async {
        do { try await runChecks() }
        catch {
            FileHandle.standardError.write(Data("Routing checks failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runChecks() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ContextRoute-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let browser = BrowserCatalog.browser(bundleIdentifier: "com.google.Chrome")
            ?? BrowserCatalog.browser(bundleIdentifier: "com.apple.Safari") else {
            throw CheckFailure(description: "Routing checks need an installed Chrome or Safari.")
        }
        try checkDecisions(browser: browser, scratch: scratch)
        try await checkProfileLaunches(scratch: scratch)
        print("Routing checks: \(assertions) assertions passed; no links opened in installed applications.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(description: message) }
        assertions += 1
    }

    private static func checkDecisions(browser: BrowserInfo, scratch: URL) throws {
        let url = URL(string: "https://example.com/path?token=fixture#fragment")!
        let source = "test.ContextRoute.source"
        var configuration = RouterConfiguration(urlAppOverrides: [],
            fallbackBrowserBundleIdentifier: browser.bundleIdentifier, fallbackBrowserName: browser.name)
        func decide(_ value: URL = url, sourceID: String? = source) -> RouteDecision {
            RoutePlanner.decide(value, sourceBundleIdentifier: sourceID, snapshot: RoutePlanner.prepare(configuration))
        }

        try require(decide(URL(string: "ftp://example.com")!).kind == .unavailable, "Reject non-web schemes")
        try require(decide(URL(string: "https:/path")!).kind == .unavailable, "Reject links without a host")
        try require(decide(sourceID: nil).kind == .fallback, "Unknown sources use the fallback browser")
        if case let .application(appURL, routedURL) = decide().destination {
            try require(appURL == browser.appURL && routedURL == url, "Preserve the complete URL")
        } else { throw CheckFailure(description: "Expected fallback application destination") }

        configuration.fallbackBrowserBundleIdentifier = nil
        try require(decide().kind == .unavailable, "Missing fallback reports an unavailable route")
        configuration.fallbackBrowserBundleIdentifier = "test.ContextRoute.notInstalled"
        try require(decide().kind == .unavailable, "Missing browser is rejected")
        configuration.fallbackBrowserBundleIdentifier = "com.apple.finder"
        try require(decide().kind == .unavailable, "Non-browser fallback is rejected")
        if let ownID = Bundle.main.bundleIdentifier {
            configuration.fallbackBrowserBundleIdentifier = ownID
            try require(decide().kind == .unavailable, "Never route back into ContextRoute")
        }
        configuration.fallbackBrowserBundleIdentifier = browser.bundleIdentifier

        var route = SourceRoute(sourceBundleIdentifier: source, sourceName: "Fixture",
            browserBundleIdentifier: browser.bundleIdentifier, browserName: browser.name,
            profileIdentifier: nil, profileName: nil, userDataDirectory: nil)
        configuration.sourceRoutes = [route]
        try require(decide().kind == .appRoute, "Enabled app route wins over fallback")
        try require(decide(sourceID: "test.ContextRoute.otherSource").kind == .fallback, "Match the source exactly")
        route.isEnabled = false
        configuration.sourceRoutes = [route]
        try require(decide().kind == .fallback, "Disabled app route uses fallback")
        route.isEnabled = true
        route.browserBundleIdentifier = "test.ContextRoute.notInstalled"
        configuration.sourceRoutes = [route]
        try require(decide().kind == .fallback && decide().warnings.count == 1, "Missing app-route browser warns and falls back")
        route.browserBundleIdentifier = browser.bundleIdentifier

        if BrowserCatalog.supportsProfiles(for: browser) {
            route.userDataDirectory = scratch.appendingPathComponent("Profile data").path
            let profile = URL(fileURLWithPath: route.userDataDirectory!).appendingPathComponent("Default")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            route.profileIdentifier = "Default"
            configuration.sourceRoutes = [route]
            try require(decide().kind == .appRoute, "Available profile stays on its app route")
            if case let .profile(executableURL, arguments, routedURL) = decide().destination {
                let expectedArguments = BrowserCatalog.profileLaunchArguments(browser: browser,
                    profileIdentifier: "Default", userDataDirectory: route.userDataDirectory)
                try require(executableURL == BrowserCatalog.executableURL(for: browser.appURL) && arguments == expectedArguments && routedURL == url,
                    "Preserve the selected profile and complete URL")
            } else { throw CheckFailure(description: "Expected profile destination") }
            route.profileIdentifier = "missing-profile"
            configuration.sourceRoutes = [route]
            try require(decide().kind == .fallback && !decide().warnings.isEmpty, "Missing profile warns and falls back")
            route.profileIdentifier = "../outside"
            configuration.sourceRoutes = [route]
            try require(decide().kind == .fallback && !decide().warnings.isEmpty, "Reject invalid profile identifiers")
            route.profileIdentifier = ""
            configuration.sourceRoutes = [route]
            try require(decide().kind == .fallback, "Empty imported profile does not launch a new browser profile")
        }
        route.profileIdentifier = nil
        configuration.sourceRoutes = [route]

        var handler = URLAppOverride(id: "fixture", name: "Fixture handler", hosts: ["example.com"],
            candidateBundleIdentifiers: [browser.bundleIdentifier], appNameHints: [])
        configuration.urlAppOverrides = [handler]
        try require(decide().kind == .handler, "App handler wins over an app route")
        handler.isEnabled = false
        configuration.urlAppOverrides = [handler]
        try require(decide().kind == .appRoute, "Disabled handler uses the app route")
        handler.isEnabled = true
        handler.candidateBundleIdentifiers = ["test.ContextRoute.notInstalled"]
        configuration.urlAppOverrides = [handler]
        try require(decide().kind == .appRoute && !decide().warnings.isEmpty, "Missing handler warns and continues routing")
        route.isEnabled = false
        configuration.sourceRoutes = [route]
        handler.candidateBundleIdentifiers = [browser.bundleIdentifier]
        configuration.urlAppOverrides = [handler]
        try require(decide().kind == .handler, "Handler works even when the source route is disabled")

        let zoom = URLAppOverride.defaults.first { $0.id == "zoom" }!
        try require(zoom.matches(URL(string: "https://team.zoom.us/j/123")!), "Zoom meeting matches subdomains")
        try require(!zoom.matches(URL(string: "https://zoom.us/pricing")!), "Zoom website pages stay in a browser")
        try require(!zoom.matches(URL(string: "https://zoom.us.attacker.example/j/123")!), "Host suffix lookalikes do not match")
        let telegram = URLAppOverride.defaults.first { $0.id == "telegram" }!
        try require(telegram.matches(URL(string: "https://t.me/fixture")!), "Telegram links match their handler")
        try require(!telegram.matches(URL(string: "https://sub.t.me/fixture")!), "Exact Telegram host stays exact")
        let slack = URLAppOverride.defaults.first { $0.id == "slack" }!
        try require(slack.matches(URL(string: "https://team.slack.com/archives/fixture")!), "Slack conversation links match")
        try require(!slack.matches(URL(string: "https://slack.com/pricing")!), "Slack website pages stay in a browser")
        let discord = URLAppOverride.defaults.first { $0.id == "discord" }!
        let translated = discord.translatedURL(URL(string: "https://discord.gg/invite-code?fixture=1#fragment")!)
        try require(translated.scheme == "discord" && translated.host == "-" && translated.path == "/invite/invite-code",
            "Translate Discord invites")
        try require(translated.query == "fixture=1" && translated.fragment == "fragment", "Preserve Discord query and fragment")
    }

    private static func checkProfileLaunches(scratch: URL) async throws {
        let launcher = BrowserLauncher()
        let url = URL(string: "https://example.com/path?fixture=1#fragment")!
        let dataDirectory = scratch.appendingPathComponent("Profile data")
        let route = SourceRoute(sourceBundleIdentifier: "test.source", sourceName: "Fixture",
            browserBundleIdentifier: "com.google.Chrome", browserName: "Test Chromium",
            profileIdentifier: "Default", profileName: nil, userDataDirectory: dataDirectory.path)

        func destination(for browser: BrowserInfo, arguments: [String]? = nil) -> RouteDestination {
            .profile(executableURL: BrowserCatalog.executableURL(for: browser.appURL)!,
                arguments: arguments ?? BrowserCatalog.profileLaunchArguments(browser: browser,
                    profileIdentifier: route.profileIdentifier!, userDataDirectory: route.userDataDirectory)!, url: url)
        }

        for status in [Int32(0), Int32(7)] {
            let fixture = try makeFixture(in: scratch, status: status, executable: true)
            let recording = LaunchRecording()
            launcher.open(destination(for: fixture.browser)) {
                if let error = $0 { recording.errors.append(error) }
            }
            let expectedArguments = ["--user-data-dir=\(dataDirectory.path)", "--profile-directory=Default", url.absoluteString]
            try await waitFor {
                (try? String(contentsOf: fixture.arguments, encoding: .utf8)) == expectedArguments.joined(separator: "\n") + "\n"
            }
            if status != 0 {
                try await waitFor { !recording.errors.isEmpty }
                try require(recording.errors[0].localizedDescription.contains(String(status)), "Preserve the child exit status")
            }
            try require(recording.errors.count == (status == 0 ? 0 : 1), "Report a nonzero early exit once")
            let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8).split(separator: "\n").map(String.init)
            try require(arguments == expectedArguments,
                "Profile launch preserves spaces and the complete URL as separate arguments")
        }

        let fixture = try makeFixture(in: scratch, status: 0, executable: false)
        let recording = LaunchRecording()
        launcher.open(destination(for: fixture.browser)) {
            if let error = $0 { recording.errors.append(error) }
        }
        try await waitFor { !recording.errors.isEmpty }
        try require(recording.errors.count == 1, "Spawn failure reports an error once")

        let unavailable = LaunchRecording()
        launcher.open(.unavailable) {
            if let error = $0 { unavailable.errors.append(error) }
        }
        try require(unavailable.errors.count == 1, "Unavailable destination reports an error")

        let invalidProfile = LaunchRecording()
        launcher.open(destination(for: fixture.browser, arguments: [])) {
            if let error = $0 { invalidProfile.errors.append(error) }
        }
        try require(invalidProfile.errors.count == 1, "Invalid profile request reports an error")
    }

    private static func waitFor(_ condition: () -> Bool) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000 else {
                throw CheckFailure(description: "Timed out waiting for a fixture process")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func makeFixture(in scratch: URL, status: Int32, executable: Bool) throws -> (browser: BrowserInfo, arguments: URL) {
        let appURL = scratch.appendingPathComponent("\(UUID().uuidString)/Test Chromium.app")
        let contents = appURL.appendingPathComponent("Contents")
        let executableURL = contents.appendingPathComponent("MacOS/fixture")
        let argumentsURL = appURL.deletingLastPathComponent().appendingPathComponent("arguments.txt")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleExecutable": "fixture", "CFBundleIdentifier": "test.ContextRoute.fixture",
            "CFBundleName": "Test Chromium", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let quotedPath = "'" + argumentsURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(quotedPath)\nexit \(status)\n"
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: executableURL.path)
        return (BrowserInfo(bundleIdentifier: "com.google.Chrome", name: "Test Chromium", appURL: appURL), argumentsURL)
    }
}
