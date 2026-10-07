import AppKit
import SwiftUI

@main
struct ContextRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RouterModel.shared
    @AppStorage(InterfaceLanguage.defaultsKey) private var languageRawValue = InterfaceLanguage.english.rawValue

    private var interfaceLocale: Locale {
        InterfaceLanguage(rawValue: languageRawValue)?.locale ?? InterfaceLanguage.english.locale
    }

    var body: some Scene {
        MenuBarExtra("ContextRoute", systemImage: "arrow.triangle.branch") {
            Group {
                Button("Settings…") { appDelegate.showSettingsWindow() }
                Divider()
                Text(model.statusMessage)
                    .lineLimit(3)
                Divider()
                Button("Quit ContextRoute") { NSApp.terminate(nil) }
            }
            .environment(\.locale, interfaceLocale)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func showSettingsWindow() {
        if let settingsWindow {
            bringSettingsWindowForward(settingsWindow)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(model: RouterModel.shared))
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 760, height: 540))
        window.title = "ContextRoute"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 700, height: 450)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        bringSettingsWindowForward(window)
    }

    private func bringSettingsWindowForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // A menu-bar action can run before menu tracking finishes and activation takes effect.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(event:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = RouterModel.shared.captureCurrentDefaultBrowserIfPossible()
    }

    @objc func handleGetURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: rawURL) else { return }

        let sourceBundleIdentifier: String?
        if let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) {
            let pid = pid_t(sender.int32Value)
            sourceBundleIdentifier = pid > 0
                ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                : nil
        } else {
            sourceBundleIdentifier = nil
        }

        Task { @MainActor in
            RouterModel.shared.route(url, sourceBundleIdentifier: sourceBundleIdentifier)
        }
    }
}
