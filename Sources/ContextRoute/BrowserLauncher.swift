import AppKit

@MainActor
final class BrowserLauncher {
    private var processes: [UUID: Process] = [:]
    private let launchQueue = DispatchQueue(label: "ContextRoute.profileLaunch", qos: .userInitiated)

    func open(
        _ destination: RouteDestination,
        trace: RoutingTrace? = nil,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        switch destination {
        case let .application(appURL, url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            trace?.mark("launch-requested", details: "mode=launch-services destination=application")
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                trace?.mark("launch-services-completed", details: "success=\(error == nil)")
                DispatchQueue.main.async { completion(error) }
            }
        case let .profile(appURL, bundleIdentifier, executableURL, profileArguments, url):
            guard !profileArguments.isEmpty else {
                completion(LaunchError(key: "The selected profile cannot be opened."))
                return
            }
            var arguments = profileArguments
            arguments.append(url.absoluteString)

            let runningBrowsers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            let browserIsRunning = !runningBrowsers.isEmpty
            let appBundleIdentifier = Bundle(url: appURL)?.bundleIdentifier
            let appBundleMatchesRoute = appBundleIdentifier.map {
                $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            } ?? false
            if appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
               appBundleMatchesRoute,
               !browserIsRunning {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.arguments = arguments
                trace?.mark("launch-requested", details: "mode=launch-services destination=profile browser_running=false")
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                    trace?.mark("launch-services-completed", details: "destination=profile success=\(error == nil)")
                    DispatchQueue.main.async { completion(error) }
                }
                return
            }

            let process = Process()
            let id = UUID()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            processes[id] = process
            let singletonDirectory = browserIsRunning
                ? BrowserCatalog.chromiumUserDataDirectory(bundleIdentifier: bundleIdentifier, arguments: profileArguments) : nil
            let runningPIDs = Set(runningBrowsers.map(\.processIdentifier))
            trace?.mark("launch-requested", details: "mode=\(singletonDirectory == nil ? "process" : "ipc") destination=profile browser_running=\(browserIsRunning)")
            // Launching a profile can wait on executable validation or process creation.
            // Keep those waits off the event loop, and preserve the order of profile launches.
            let queuedAt = trace.map { _ in DispatchTime.now().uptimeNanoseconds }
            launchQueue.async { [weak self] in
                let started = DispatchTime.now().uptimeNanoseconds
                let queueWait = queuedAt.map { (started - $0) / 1_000_000 }
                if let queueWait {
                    trace?.mark("profile-delivery-queue-start", details: "queue_wait_ms=\(queueWait)")
                }
                if let singletonDirectory {
                    trace?.mark("profile-ipc-started")
                    switch ChromiumSingleton.deliver(in: singletonDirectory, executableURL: executableURL,
                        arguments: arguments, expectedPIDs: runningPIDs) {
                    case let .delivered(pid):
                        trace?.mark("profile-ipc-acknowledged", details: "pid=\(pid)")
                        DispatchQueue.main.async {
                            self?.processes[id] = nil
                            NSRunningApplication(processIdentifier: pid)?.activate()
                            trace?.mark("running-browser-activated")
                            completion(nil)
                        }
                        return
                    case let .unavailable(reason):
                        trace?.mark("profile-ipc-unavailable", details: "reason=\(reason)")
                    case .unconfirmed:
                        trace?.mark("profile-ipc-unconfirmed")
                        DispatchQueue.main.async {
                            self?.processes[id] = nil
                            completion(LaunchError(key: "The browser didn't confirm the link. It may still open; retry only if it doesn't."))
                        }
                        return
                    }
                    trace?.mark("profile-process-fallback")
                }
                let processStartedAt = DispatchTime.now().uptimeNanoseconds
                process.terminationHandler = { [weak self] finished in
                    let status = finished.terminationStatus
                    trace?.mark("profile-process-terminated", details: "pid=\(finished.processIdentifier) status=\(status) lifetime_ms=\((DispatchTime.now().uptimeNanoseconds - processStartedAt) / 1_000_000)")
                    let failedEarly = status != 0 && DispatchTime.now().uptimeNanoseconds - processStartedAt < 10_000_000_000
                    DispatchQueue.main.async {
                        self?.processes[id] = nil
                        if failedEarly {
                            completion(LaunchError(key: "The browser exited with code %@ while opening the link.", arguments: [String(status)]))
                        }
                    }
                }
                do {
                    try process.run()
                    trace?.mark("profile-process-run-return",
                        details: "pid=\(process.processIdentifier) run_ms=\((DispatchTime.now().uptimeNanoseconds - processStartedAt) / 1_000_000)")
                    DispatchQueue.main.async {
                        if let browser = NSRunningApplication.runningApplications(
                            withBundleIdentifier: bundleIdentifier).first {
                            browser.activate()
                            trace?.mark("running-browser-activated")
                        }
                    }
                } catch {
                    if let queueWait {
                        trace?.mark("profile-process-run-failed", details: "queue_wait_ms=\(queueWait)")
                    }
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
