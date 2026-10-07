import AppKit

/// A detached native menu dispatches editing shortcuts without a visible Edit menu.
/// AppKit handles keyboard layouts, action validation and the text responder chain.
@MainActor
final class EditingCommandState: NSObject, NSMenuItemValidation {
    private let shortcuts = NSMenu()
    private var eventMonitor: Any?

    override init() {
        super.init()
        addShortcut("Undo", action: #selector(undo(_:)), key: "z", target: self)
        addShortcut("Redo", action: #selector(redo(_:)), key: "z", modifiers: [.command, .shift], target: self)
        addShortcut("Cut", action: #selector(NSText.cut(_:)), key: "x")
        addShortcut("Copy", action: #selector(NSText.copy(_:)), key: "c")
        addShortcut("Paste", action: #selector(NSText.paste(_:)), key: "v")
        addShortcut("Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift])
        addShortcut("Select All", action: #selector(NSText.selectAll(_:)), key: "a")
    }

    private func addShortcut(_ title: String, action: Selector, key: String,
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: ContextRouteLocalization.string(title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        shortcuts.addItem(item)
    }

    func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), NSApp.keyWindow != nil else { return event }
            self.shortcuts.update()
            return self.shortcuts.performKeyEquivalent(with: event) ? nil : event
        }
    }

    func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private var textEditor: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }
    private var acceptsRoutingUndo: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return window.sheetParent == nil && window.attachedSheet == nil && !(window is NSSavePanel)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            if let textEditor { return textEditor.undoManager?.canUndo == true }
            return acceptsRoutingUndo && RouterModel.shared.canUndo
        }
        if menuItem.action == #selector(redo(_:)) {
            if let textEditor { return textEditor.undoManager?.canRedo == true }
            return acceptsRoutingUndo && RouterModel.shared.canRedo
        }
        return false
    }

    @objc private func undo(_ sender: NSMenuItem) {
        if let textEditor {
            if let manager = textEditor.undoManager, manager.canUndo { manager.undo() }
        } else if acceptsRoutingUndo { RouterModel.shared.undo() }
    }

    @objc private func redo(_ sender: NSMenuItem) {
        if let textEditor {
            if let manager = textEditor.undoManager, manager.canRedo { manager.redo() }
        } else if acceptsRoutingUndo { RouterModel.shared.redo() }
    }
}
