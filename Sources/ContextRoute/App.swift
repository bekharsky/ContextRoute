import AppKit
import SwiftUI

@main
struct ContextRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RouterModel.shared
    @StateObject private var windowCommands = WindowCommandState()
    @AppStorage(InterfaceLanguage.defaultsKey) private var languageRawValue = InterfaceLanguage.english.rawValue

    private var interfaceLocale: Locale {
        InterfaceLanguage(rawValue: languageRawValue)?.locale ?? InterfaceLanguage.english.locale
    }

    var body: some Scene {
        MenuBarExtra("ContextRoute", systemImage: model.routingIssue?.needsAttention == true || model.storageError != nil
            ? "exclamationmark.triangle" : "arrow.triangle.branch") {
            Group {
                if !model.isContextRouteDefaultHandler {
                    Button("Make default browser…") { appDelegate.showLinkSetup() }
                    Divider()
                }
                Button("Settings…") { appDelegate.showSettingsWindow() }
                Button("About ContextRoute") { appDelegate.showAboutWindow() }
                Divider()
                Button("Quit ContextRoute") { NSApp.terminate(nil) }
            }
            .environment(\.locale, interfaceLocale)
            .onAppear { model.refreshDefaultHandlerStatus() }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ContextRoute") { appDelegate.showAboutWindow() }
                    .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                    .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit ContextRoute") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!windowCommands.canClose)
                .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .printItem) { }
            MinimalMenuCommands()
            WindowMenuCommands(windows: windowCommands, locale: interfaceLocale)
        }
    }
}

private struct MinimalMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) { }
        CommandGroup(replacing: .pasteboard) { }
        CommandGroup(replacing: .textEditing) { }
        CommandGroup(replacing: .textFormatting) { }
        CommandGroup(replacing: .toolbar) { }
        CommandGroup(replacing: .sidebar) { }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let showLinkSetupNotification = Notification.Name("ContextRoute.ShowLinkSetup")
    static let showRoutingFailureNotification = Notification.Name("ContextRoute.ShowRoutingFailure")
    private var settingsWindow: NSWindow?
    private let focusVisibility = SettingsFocusVisibility()
    private let editingCommands = EditingCommandState()
    private let textUndoManager = UndoManager()
    private var windowCloseObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuCleanupScheduled = false
    private var isTerminating = false
    private let processStartedAt = RoutingDiagnostics.isEnabled ? DispatchTime.now().uptimeNanoseconds : nil

    func showSettingsWindow() {
        RouterModel.shared.refreshDefaultHandlerStatus()
        focusVisibility.prepareForPresentation()
        if let settingsWindow {
            bringSettingsWindowForward(settingsWindow)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(model: RouterModel.shared, focusVisibility: focusVisibility))
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 760, height: 540))
        window.title = "ContextRoute"
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 700, height: 450)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window

        bringSettingsWindowForward(window)
    }

    func showLinkSetup() {
        showSettingsWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.showLinkSetupNotification, object: nil)
        }
    }

    func showAboutWindow() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: ContextRouteLocalization.format("Created by %@", arguments: ["Sergey Bekharskiy"]),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ContextRoute",
            .credits: credits
        ]
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }

        activateForWindow()
        NSApp.orderFrontStandardAboutPanel(options: options)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: options)
        }
    }

    private func bringSettingsWindowForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        activateForWindow()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // A menu-bar action can run before menu tracking finishes and activation takes effect.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func activateForWindow() {
        // An accessory app has no application menu. Use the regular policy while
        // a user-facing window is open, and return to the menu bar when it closes.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleMenuCleanup()
    }

    private func scheduleMenuCleanup() {
        guard !menuCleanupScheduled else { return }
        menuCleanupScheduled = true
        // SwiftUI constructs command groups incrementally. Wait until the menu update finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuCleanupScheduled = false
            guard let mainMenu = NSApp.mainMenu else { return }
            for item in mainMenu.items {
                guard let submenu = item.submenu else { continue }
                let isEmpty = !self.hasCommands(in: submenu)
                if item.isHidden != isEmpty { item.isHidden = isEmpty }
            }
        }
    }

    private func hasCommands(in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            guard !item.isSeparatorItem, !item.isHidden else { return false }
            if let submenu = item.submenu { return hasCommands(in: submenu) }
            return item.action != nil || item.view != nil
        }
    }

    private func returnToMenuBarIfNoWindows(excluding closingWindow: NSWindow) {
        guard !isTerminating else { return }
        let hasOpenWindow = NSApp.windows.contains { window in
            window !== closingWindow && window.canBecomeKey && (window.isVisible || window.isMiniaturized)
        }
        if !hasOpenWindow, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        RoutingDiagnostics.logAppStage("will-finish", startedAt: processStartedAt)
        NSWindow.allowsAutomaticWindowTabbing = false
        editingCommands.startMonitoring()
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard var menu = notification.object as? NSMenu, let mainMenu = NSApp.mainMenu else { return }
                while menu !== mainMenu {
                    guard let parent = menu.supermenu else { return }
                    menu = parent
                }
                MainActor.assumeIsolated { self?.scheduleMenuCleanup() }
            })
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow, window.canBecomeKey else { return }
            // AppKit posts willClose before updating its visible-window list.
            DispatchQueue.main.async { [weak self] in
                self?.returnToMenuBarIfNoWindows(excluding: window)
            }
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(event:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RoutingDiagnostics.logAppStage("did-finish-start", startedAt: processStartedAt)
        let showsWindowOnLaunch = isInteractiveLaunch(notification)
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = AppearanceChoice.current.nativeAppearance
        let model = RouterModel.shared
        model.onRoutingFailure = { [weak self] in
            self?.showSettingsWindow()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.showRoutingFailureNotification, object: nil)
            }
        }
        _ = model.captureCurrentDefaultBrowserIfPossible()
        model.refreshDefaultHandlerStatus()
        RoutingDiagnostics.logAppStage("routing-ready", startedAt: processStartedAt)
        guard showsWindowOnLaunch else { return }

        let setupKey = "app.contextroute.hasPresentedInitialSetup"
        let needsInitialSetup = !UserDefaults.standard.bool(forKey: setupKey) && !model.isContextRouteDefaultHandler
        UserDefaults.standard.set(true, forKey: setupKey)
        if needsInitialSetup { showLinkSetup() }
        else { showSettingsWindow() }
    }

    private func isInteractiveLaunch(_ notification: Notification) -> Bool {
        // The launch Apple event is only available during didFinishLaunching.
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            guard event.eventID == AEEventID(kAEOpenApplication) || event.eventID == AEEventID(kAEReopenApplication) else { return false }
            let launchReason = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            return launchReason != OSType(keyAELaunchedAsLogInItem)
                && launchReason != OSType(keyAELaunchedAsServiceItem)
        }
        return notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleMenuCleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        editingCommands.stopMonitoring()
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        textUndoManager
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == NSUserActivityTypeBrowsingWeb
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return false }

        // Web Handoff has no local source process; use app handlers and the fallback browser.
        routeIncomingURL(url, sourceBundleIdentifier: nil, fromHandoff: true)
        return true
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

        routeIncomingURL(url, sourceBundleIdentifier: sourceBundleIdentifier)
    }

    private func routeIncomingURL(_ url: URL, sourceBundleIdentifier: String?, fromHandoff: Bool = false) {
        let trace = RoutingTrace(processStartedAt: processStartedAt)
        trace?.mark("url-received", details: "source_known=\(sourceBundleIdentifier != nil) handoff=\(fromHandoff)")
        Task { @MainActor in
            RouterModel.shared.route(url, sourceBundleIdentifier: sourceBundleIdentifier, trace: trace)
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "app.contextroute.appearance"

    static var current: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
