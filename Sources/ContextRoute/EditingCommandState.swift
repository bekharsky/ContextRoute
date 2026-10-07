import AppKit
import Combine

/// Keep text-field undo separate from undoing changes to routing settings.
@MainActor
final class EditingCommandState: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasTextEditor = false
    private var observers: Set<AnyCancellable> = []

    init() {
        for name in [NSText.didChangeNotification, NSControl.textDidChangeNotification,
                     NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification,
                     NSWindow.didBecomeKeyNotification, NSMenu.didBeginTrackingNotification,
                     Notification.Name.NSUndoManagerDidCloseUndoGroup, Notification.Name.NSUndoManagerDidUndoChange,
                     Notification.Name.NSUndoManagerDidRedoChange] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        }
    }

    private var textUndoManager: UndoManager? { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager }

    private func refresh() {
        hasTextEditor = NSApp.keyWindow?.firstResponder is NSTextView
        canUndo = textUndoManager?.canUndo ?? false
        canRedo = textUndoManager?.canRedo ?? false
    }

    func undo(_ model: RouterModel) {
        if let manager = textUndoManager {
            if manager.canUndo { manager.undo() }
        } else { model.undo() }
        refresh()
    }

    func redo(_ model: RouterModel) {
        if let manager = textUndoManager {
            if manager.canRedo { manager.redo() }
        } else { model.redo() }
        refresh()
    }
}
