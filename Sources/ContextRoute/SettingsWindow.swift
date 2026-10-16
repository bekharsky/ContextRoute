import AppKit
import QuartzCore
import SwiftUI

final class SettingsFocusVisibility: ObservableObject {
    @Published private(set) var usesKeyboard = false
    private weak var window: NSWindow?
    private var eventMonitor: Any?
    private let originalRingTypes = NSMapTable<NSView, NSNumber>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func prepareForPresentation() {
        setUsesKeyboard(NSApp.currentEvent?.type == .keyDown)
    }

    func attach(to window: NSWindow) {
        self.window = window
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    guard let eventWindow = event.window ?? NSApp.keyWindow,
                          self.settingsWindows.contains(where: { $0 === eventWindow }) else { return event }
                    self.setUsesKeyboard(true)
                } else {
                    self.setUsesKeyboard(false)
                }
                return event
            }
        }
        refreshNativeFocus()
        // SwiftUI may create native controls after its representable update finishes.
        DispatchQueue.main.async { [weak self] in self?.refreshNativeFocus() }
    }

    private var settingsWindows: [NSWindow] {
        guard let window else { return [] }
        func includingSheets(_ window: NSWindow) -> [NSWindow] {
            [window] + window.sheets.flatMap(includingSheets)
        }
        return includingSheets(window)
    }

    private func setUsesKeyboard(_ value: Bool) {
        if usesKeyboard != value { usesKeyboard = value }
        refreshNativeFocus()
        DispatchQueue.main.async { [weak self] in self?.refreshNativeFocus() }
    }

    private func refreshNativeFocus() {
        for window in settingsWindows {
            // The frame view also contains the native toolbar controls.
            if let root = window.contentView?.superview ?? window.contentView {
                let windowButtons = Set([
                    NSWindow.ButtonType.closeButton,
                    .miniaturizeButton,
                    .zoomButton
                ].compactMap { window.standardWindowButton($0) }.map(ObjectIdentifier.init))
                updateRingTypes(in: root, excluding: windowButtons)
            }
        }
    }

    private func updateRingTypes(in view: NSView, excluding windowButtons: Set<ObjectIdentifier>) {
        guard !windowButtons.contains(ObjectIdentifier(view)) else { return }
        if view is NSTableView || view is NSScrollView {
            // Lists indicate focus through selection, without outlining the entire pane.
            if view.focusRingType != .none {
                view.focusRingType = .none
                view.noteFocusRingMaskChanged()
            }
        } else if view is NSControl {
            updateControlRingType(view)
        }
        for child in view.subviews { updateRingTypes(in: child, excluding: windowButtons) }
    }

    private func updateControlRingType(_ view: NSView) {
        let originalType: NSFocusRingType
        if let savedType = originalRingTypes.object(forKey: view) {
            originalType = NSFocusRingType(rawValue: savedType.uintValue) ?? .default
        } else {
            // SwiftUI may create a control while its focus effect is already disabled.
            originalType = !usesKeyboard && view.focusRingType == .none
                ? type(of: view).defaultFocusRingType
                : view.focusRingType
            originalRingTypes.setObject(NSNumber(value: originalType.rawValue), forKey: view)
        }
        let ringType: NSFocusRingType = usesKeyboard ? originalType : .none
        if view.focusRingType != ringType {
            view.focusRingType = ringType
            view.noteFocusRingMaskChanged()
        }
    }
}

/// Keep focus changes inside each hosting tree instead of replacing its root view.
struct SettingsFocusContent<Content: View>: View {
    @ObservedObject var focusVisibility: SettingsFocusVisibility
    let content: Content

    var body: some View {
        content.focusEffectDisabled(!focusVisibility.usesKeyboard)
    }
}

struct SettingsSplitContainer: NSViewControllerRepresentable {
    struct SidebarState: Equatable {
        let selectedSection: SettingsSection
        let searchQuery: String
        let searchResults: [SettingsSearchResult]
        let isDefaultHandler: Bool
        let language: String
        let appearance: String
    }

    let sidebar: AnyView
    let sidebarState: SidebarState
    let detail: AnyView
    let sheetContent: AnyView
    @Binding var isPresentingSheet: Bool
    let focusVisibility: SettingsFocusVisibility
    @Binding var searchText: String
    let title: String
    let showsRefresh: Bool
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: SettingsSplitController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 760, height: proposal.height ?? 540)
    }

    func makeNSViewController(context: Context) -> SettingsSplitController {
        let controller = SettingsSplitController(sidebar: sidebar, detail: detail)
        context.coordinator.attach(to: controller, focusVisibility: focusVisibility, sidebarState: sidebarState)
        controller.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(in: window)
        }
        return controller
    }

    func updateNSViewController(_ controller: SettingsSplitController, context: Context) {
        context.coordinator.update(
            sheetContent: sheetContent,
            isPresentingSheet: $isPresentingSheet,
            searchText: $searchText,
            title: title,
            showsRefresh: showsRefresh,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward,
            onBack: onBack,
            onForward: onForward,
            onRefresh: onRefresh)
        context.coordinator.updateSidebar(sidebar, state: sidebarState)
        controller.detailHost.rootView = detail
        context.coordinator.install(in: controller.view.window)
    }

    final class Coordinator: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
        private static let toolbarIdentifier = NSToolbar.Identifier("ContextRoute.SettingsToolbar")
        private static let separatorIdentifier = NSToolbarItem.Identifier("ContextRoute.SidebarSeparator")
        private static let sidebarIdentifier = NSToolbarItem.Identifier("ContextRoute.SidebarToggle")
        private static let navigationIdentifier = NSToolbarItem.Identifier("ContextRoute.Navigation")
        private static let titleIdentifier = NSToolbarItem.Identifier("ContextRoute.SectionTitle")
        private static let refreshIdentifier = NSToolbarItem.Identifier("ContextRoute.Refresh")

        private weak var controller: SettingsSplitController?
        private var sidebarState: SidebarState?
        private weak var window: NSWindow?
        private weak var focusVisibility: SettingsFocusVisibility?
        private var toolbar: NSToolbar?
        private var collapseObservation: NSKeyValueObservation?
        private var searchText: Binding<String>?
        private var title = ""
        private var showsRefresh = true
        private var canNavigateBack = false
        private var canNavigateForward = false
        private var onBack: () -> Void = {}
        private var onForward: () -> Void = {}
        private var onRefresh: () -> Void = {}
        private var sidebarItem: NSToolbarItem?
        private var navigationItem: NSToolbarItemGroup?
        private var titleItem: NSToolbarItem?
        private var titleField: NSTextField?
        private var sheetContent = AnyView(EmptyView())
        private var isPresentingSheet: Binding<Bool>?
        private var routeSheet: NSWindow.HostingSheetRepresentation<AnyView>?
        private var sheetUpdateScheduled = false

        func attach(to controller: SettingsSplitController, focusVisibility: SettingsFocusVisibility, sidebarState: SidebarState) {
            self.controller = controller
            self.focusVisibility = focusVisibility
            self.sidebarState = sidebarState
            controller.searchAccessory.searchField.delegate = self
            collapseObservation = controller.sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                self?.updateSidebarItem()
            }
        }

        func updateSidebar(_ sidebar: AnyView, state: SidebarState) {
            guard let controller, sidebarState != state else { return }
            sidebarState = state
            controller.sidebarHost.rootView = sidebar
        }

        func update(
            sheetContent: AnyView,
            isPresentingSheet: Binding<Bool>,
            searchText: Binding<String>,
            title: String,
            showsRefresh: Bool,
            canNavigateBack: Bool,
            canNavigateForward: Bool,
            onBack: @escaping () -> Void,
            onForward: @escaping () -> Void,
            onRefresh: @escaping () -> Void
        ) {
            self.sheetContent = sheetContent
            self.isPresentingSheet = isPresentingSheet
            self.searchText = searchText
            self.title = title
            self.showsRefresh = showsRefresh
            self.canNavigateBack = canNavigateBack
            self.canNavigateForward = canNavigateForward
            self.onBack = onBack
            self.onForward = onForward
            self.onRefresh = onRefresh

            if let field = controller?.searchAccessory.searchField {
                if field.stringValue != searchText.wrappedValue {
                    field.stringValue = searchText.wrappedValue
                }
                field.placeholderString = ContextRouteLocalization.string("Search settings")
                field.setAccessibilityLabel(ContextRouteLocalization.string("Search settings"))
            }
            updateToolbarItems()
            if window?.title != title { window?.title = title }
            scheduleSheetUpdate()
        }

        func install(in window: NSWindow?) {
            guard let window, let controller, searchText != nil else { return }
            self.window = window
            focusVisibility?.attach(to: window)
            scheduleSheetUpdate()

            guard window.toolbar?.identifier != Self.toolbarIdentifier else { return }

            window.title = title
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
            window.toolbar = toolbar
            controller.view.layoutSubtreeIfNeeded()
            focusVisibility?.attach(to: window)
        }

        private func scheduleSheetUpdate() {
            guard !sheetUpdateScheduled else { return }
            sheetUpdateScheduled = true
            // Finish the hosting-view update before AppKit starts the sheet transition.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sheetUpdateScheduled = false
                self.updateSheetPresentation()
            }
        }

        private func updateSheetPresentation() {
            guard let window, let isPresentingSheet else { return }
            if isPresentingSheet.wrappedValue {
                if let routeSheet {
                    routeSheet.rootView = sheetContent
                } else {
                    routeSheet = window.beginSheet(content: { sheetContent }) { [weak self] in
                        guard let self else { return }
                        self.routeSheet = nil
                        self.isPresentingSheet?.wrappedValue = false
                    }
                }
                focusVisibility?.attach(to: window)
            } else if let routeSheet {
                window.endSheet(routeSheet)
            }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.separatorIdentifier, Self.sidebarIdentifier, Self.navigationIdentifier, Self.titleIdentifier, .flexibleSpace]
                + (showsRefresh ? [Self.refreshIdentifier] : [])
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.separatorIdentifier, Self.sidebarIdentifier, Self.navigationIdentifier, Self.titleIdentifier, .flexibleSpace, Self.refreshIdentifier]
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch itemIdentifier {
            case Self.separatorIdentifier:
                guard let controller else { return nil }
                return NSTrackingSeparatorToolbarItem(
                    identifier: itemIdentifier,
                    splitView: controller.splitView,
                    dividerIndex: 0)

            case Self.sidebarIdentifier:
                let item = makeItem(
                    identifier: itemIdentifier,
                    label: sidebarLabel,
                    symbol: "sidebar.left",
                    action: #selector(toggleSidebar(_:)))
                item.isNavigational = true
                sidebarItem = item
                return item

            case Self.navigationIdentifier:
                let labels = [ContextRouteLocalization.string("Back"), ContextRouteLocalization.string("Forward")]
                let item = NSToolbarItemGroup(
                    itemIdentifier: itemIdentifier,
                    images: [toolbarImage("chevron.backward", label: labels[0]), toolbarImage("chevron.forward", label: labels[1])],
                    selectionMode: .momentary,
                    labels: labels,
                    target: self,
                    action: #selector(navigate(_:)))
                item.label = ContextRouteLocalization.string("Back and forward")
                item.paletteLabel = item.label
                item.isNavigational = true
                item.isBordered = true
                item.autovalidates = false
                item.controlRepresentation = .expanded
                item.subitems[0].autovalidates = false
                item.subitems[1].autovalidates = false
                item.subitems[0].isEnabled = canNavigateBack
                item.subitems[1].isEnabled = canNavigateForward
                navigationItem = item
                return item

            case Self.titleIdentifier:
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = title
                item.paletteLabel = title
                item.isBordered = false
                let field = NSTextField(labelWithString: title)
                field.font = .systemFont(ofSize: 14, weight: .semibold)
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 1
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                field.sizeToFit()
                item.view = field
                titleItem = item
                titleField = field
                return item

            case Self.refreshIdentifier:
                return makeItem(
                    identifier: itemIdentifier,
                    label: ContextRouteLocalization.string("Refresh apps and browsers"),
                    symbol: "arrow.clockwise",
                    action: #selector(refresh(_:)))

            default:
                return nil
            }
        }

        private var sidebarLabel: String {
            ContextRouteLocalization.string(controller?.sidebarItem.isCollapsed == true ? "Show sidebar" : "Hide sidebar")
        }

        private func makeItem(
            identifier: NSToolbarItem.Identifier,
            label: String,
            symbol: String,
            action: Selector
        ) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = toolbarImage(symbol, label: label)
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = action
            return item
        }

        private func toolbarImage(_ symbol: String, label: String) -> NSImage {
            NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        }

        private func updateSidebarItem() {
            sidebarItem?.label = sidebarLabel
            sidebarItem?.paletteLabel = sidebarLabel
            sidebarItem?.toolTip = sidebarLabel
        }

        private func updateToolbarItems() {
            updateSidebarItem()
            if let navigationItem {
                navigationItem.subitems[0].isEnabled = canNavigateBack
                navigationItem.subitems[1].isEnabled = canNavigateForward
            }
            if let titleField, titleField.stringValue != title {
                titleField.stringValue = title
                titleField.sizeToFit()
                titleField.invalidateIntrinsicContentSize()
                titleItem?.label = title
                titleItem?.paletteLabel = title
            }
            if let toolbar {
                let refreshIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.refreshIdentifier }
                if showsRefresh && refreshIndex == nil {
                    toolbar.insertItem(withItemIdentifier: Self.refreshIdentifier, at: toolbar.items.count)
                } else if !showsRefresh, let refreshIndex {
                    toolbar.removeItem(at: refreshIndex)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchText?.wrappedValue = field.stringValue
        }

        @objc private func toggleSidebar(_ sender: Any?) {
            guard let controller else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                controller.sidebarItem.animator().isCollapsed = !controller.sidebarItem.isCollapsed
            }
        }

        @objc private func navigate(_ sender: NSToolbarItemGroup) {
            switch sender.selectedIndex {
            case 0 where canNavigateBack: onBack()
            case 1 where canNavigateForward: onForward()
            default: break
            }
        }

        @objc private func refresh(_ sender: Any?) {
            guard showsRefresh else { return }
            onRefresh()
        }
    }
}

final class SettingsSplitController: NSSplitViewController {
    let sidebarHost: NSHostingController<AnyView>
    let detailHost: NSHostingController<AnyView>
    let sidebarItem: NSSplitViewItem
    fileprivate let searchAccessory = SettingsSidebarSearchController()

    var windowDidChange: ((NSWindow?) -> Void)? {
        get { (splitView as? SettingsNativeSplitView)?.windowDidChange }
        set { (splitView as? SettingsNativeSplitView)?.windowDidChange = newValue }
    }

    init(sidebar: AnyView, detail: AnyView) {
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        super.init(nibName: nil, bundle: nil)
        splitView = SettingsNativeSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        sidebarItem.minimumThickness = 238
        sidebarItem.maximumThickness = 255
        sidebarItem.preferredThicknessFraction = 238.0 / 760.0
        sidebarItem.holdingPriority = .defaultHigh
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.addTopAlignedAccessoryViewController(searchAccessory)
        addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 420
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) { fatalError("Use init(sidebar:detail:)") }
}

private final class SettingsSidebarSearchController: NSSplitViewItemAccessoryViewController {
    let searchField = NSSearchField()

    override func loadView() {
        let container = NSView()
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: container.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
        automaticallyAppliesContentInsets = true
        preferredScrollEdgeEffectStyle = .soft
    }
}

private final class SettingsNativeSplitView: NSSplitView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}
