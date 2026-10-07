import AppKit
import SwiftUI

enum RouteEditorLayout {
    static let windowInset: CGFloat = 20
    static let cardInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8
    static let labelWidth: CGFloat = 96
    static let rowHeight: CGFloat = 32
    static let iconSize: CGFloat = 32
    static let activityWidth: CGFloat = 24
}

/// A system pop-up button that fills its proposed width instead of hugging its title.
struct RouteEditorPopup: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
    }

    let options: [Option]
    @Binding var selection: String
    let label: String
    var isEnabled = true

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        button.bezelStyle = .rounded
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.cell?.usesSingleLineMode = true
        button.menu = NSMenu()
        button.menu?.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectOption(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.options != options {
            context.coordinator.options = options
            button.removeAllItems()
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                button.menu?.addItem(item)
            }
        }
        button.selectItem(at: options.firstIndex { $0.id == selection } ?? -1)
        button.isEnabled = isEnabled && !options.isEmpty
        button.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsicSize = nsView.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsicSize.width
        return CGSize(width: max(0, width), height: intrinsicSize.height)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var options: [Option] = []

        init(selection: Binding<String>) { self.selection = selection }

        @objc func selectOption(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
}
