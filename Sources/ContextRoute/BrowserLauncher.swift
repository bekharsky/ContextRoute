import AppKit

@MainActor
final class BrowserLauncher {
    enum Event: Sendable {
        case started
        case processExited(status: Int32, elapsedMilliseconds: Double)
    }

    private var processes: [UUID: Process] = [:]
    private let launchQueue = DispatchQueue(label: "ContextRoute.profileLaunch", qos: .userInitiated)

    func open(_ destination: RouteDestination, onEvent: @escaping @MainActor (Event) -> Void = { _ in },
              completion: @escaping @MainActor (Error?) -> Void) {
        switch destination {
        case let .application(appURL, url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if error == nil { onEvent(.started) }
                    completion(error)
                }
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
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            processes[id] = process
            let launchQueue = launchQueue
            // Launching a profile can wait on executable validation or process creation.
            // Keep those waits off the event loop, and preserve the order of profile launches.
            launchQueue.async { [weak self] in
                let started = DispatchTime.now().uptimeNanoseconds
                process.terminationHandler = { [weak self] finished in
                    let status = finished.terminationStatus
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    // Serialize this behind run() so the started event always arrives first.
                    launchQueue.async {
                        DispatchQueue.main.async {
                            self?.processes[id] = nil
                            if elapsed < 10_000 {
                                onEvent(.processExited(status: status, elapsedMilliseconds: elapsed))
                                if status != 0 {
                                    completion(LaunchError(key: "The browser exited with code %@ while opening the link.", arguments: [String(status)]))
                                }
                            }
                        }
                    }
                }
                do {
                    try process.run()
                    DispatchQueue.main.async { onEvent(.started) }
                } catch {
                    DispatchQueue.main.async {
                        self?.processes[id] = nil
                        completion(error)
                    }
                }
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
