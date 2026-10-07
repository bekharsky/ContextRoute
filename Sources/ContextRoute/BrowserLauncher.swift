import AppKit

@MainActor
final class BrowserLauncher {
    private var processes: [UUID: Process] = [:]

    func open(_ destination: RouteDestination, completion: @escaping (Error?) -> Void) {
        switch destination {
        case let .application(appURL, url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        case let .profile(browser, route, url):
            guard let profileID = route.profileIdentifier,
                  var arguments = BrowserCatalog.profileLaunchArguments(browser: browser, profileIdentifier: profileID, userDataDirectory: route.userDataDirectory),
                  let executable = BrowserCatalog.executableURL(for: browser.appURL) else {
                completion(LaunchError(key: "The selected profile cannot be opened."))
                return
            }
            arguments.append(url.absoluteString)
            let process = Process()
            let id = UUID()
            let started = Date()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                let failedEarly = status != 0 && Date().timeIntervalSince(started) < 10
                DispatchQueue.main.async {
                    self?.processes[id] = nil
                    if failedEarly { completion(LaunchError(key: "The browser exited with code %@ while opening the link.", arguments: [String(status)])) }
                }
            }
            do {
                processes[id] = process
                try process.run()
            } catch {
                processes[id] = nil
                completion(error)
            }
        case .unavailable:
            completion(LaunchError(key: "No browser is available for this link."))
        }
    }
}

private struct LaunchError: LocalizedError {
    let key: String
    var arguments: [String] = []
    var errorDescription: String? { ContextRouteLocalization.format(key, arguments: arguments) }
}
