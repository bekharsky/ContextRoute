import AppKit
import SwiftUI

@main
struct ContextRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RouterModel.shared
    @StateObject private var editingCommands = EditingCommandState()
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
        .commandsReplaced {
            CommandGroup(replacing: .appInfo) {
                Button("About ContextRoute") { appDelegate.showAboutWindow() }
                    .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                    .environment(\.locale, interfaceLocale)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { editingCommands.undo(model) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(editingCommands.hasTextEditor ? !editingCommands.canUndo : !model.canUndo)
                    .environment(\.locale, interfaceLocale)
                Button("Redo") { editingCommands.redo(model) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(editingCommands.hasTextEditor ? !editingCommands.canRedo : !model.canRedo)
                    .environment(\.locale, interfaceLocale)
            }
            TextEditingCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let showLinkSetupNotification = Notification.Name("ContextRoute.ShowLinkSetup")
    static let showRoutingFailureNotification = Notification.Name("ContextRoute.ShowRoutingFailure")
    private var settingsWindow: NSWindow?
    private let focusVisibility = SettingsFocusVisibility()
    private let textUndoManager = UndoManager()

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
        if let icon = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "ContextRoute") {
            options[.applicationIcon] = icon.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))) ?? icon
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: options)
        }
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
        let setupKey = "app.contextroute.hasPresentedInitialSetup"
        if !UserDefaults.standard.bool(forKey: setupKey) {
            UserDefaults.standard.set(true, forKey: setupKey)
            if !model.isContextRouteDefaultHandler { showLinkSetup() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RouterModel.shared.refreshDefaultHandlerStatus()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        textUndoManager
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
