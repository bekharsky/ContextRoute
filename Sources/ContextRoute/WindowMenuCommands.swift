import AppKit
import Combine
import SwiftUI

/// Commands use AppKit's responder chain because the settings window is hosted
/// by an NSWindow rather than a SwiftUI Window scene.
struct WindowMenuCommands: Commands {
    @ObservedObject var windows: WindowCommandState
    let locale: Locale

    var body: some Commands {
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") {
                NSApp.sendAction(#selector(NSWindow.performMiniaturize(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("m", modifiers: .command)
            .disabled(!windows.canMinimize)
            .environment(\.locale, locale)
            Button("Zoom") {
                NSApp.sendAction(#selector(NSWindow.performZoom(_:)), to: nil, from: nil)
            }
            .disabled(!windows.canZoom)
            .environment(\.locale, locale)
        }
        CommandGroup(replacing: .windowArrangement) {
            Button("Bring All to Front") { NSApp.arrangeInFront(nil) }
                .disabled(!windows.hasWindows)
                .environment(\.locale, locale)
        }
    }
}

@MainActor
final class WindowCommandState: ObservableObject {
    @Published private(set) var canClose = false
    @Published private(set) var canMinimize = false
    @Published private(set) var canZoom = false
    @Published private(set) var hasWindows = false
    private var observers: Set<AnyCancellable> = []

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSMenu.didBeginTrackingNotification,
                     NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        }
        refresh()
    }

    private func refresh() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let acceptsCommands = window?.isVisible == true && window?.attachedSheet == nil && window?.sheetParent == nil
        let canClose = acceptsCommands && window?.styleMask.contains(.closable) == true
        let canMinimize = acceptsCommands && window?.styleMask.contains(.miniaturizable) == true
        let canZoom = acceptsCommands && window?.styleMask.contains(.resizable) == true
        let hasWindows = NSApp.windows.contains { $0.canBecomeKey && ($0.isVisible || $0.isMiniaturized) }
        if self.canClose != canClose { self.canClose = canClose }
        if self.canMinimize != canMinimize { self.canMinimize = canMinimize }
        if self.canZoom != canZoom { self.canZoom = canZoom }
        if self.hasWindows != hasWindows { self.hasWindows = hasWindows }
    }
}
