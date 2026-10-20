import AppKit
import SwiftUI

struct SectionIntro: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsCard<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder var content: Content

    init(inset: CGFloat = 15, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A system pop-up button that fills its proposed width instead of hugging its title.
struct SettingsPopup: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
        var isEnabled = true
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
                item.isEnabled = option.isEnabled
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
            guard let item = sender.selectedItem, item.isEnabled,
                  let id = item.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
}

struct SettingsSegmentedControl: NSViewRepresentable {
    let options: [SettingsPopup.Option]
    @Binding var selection: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.controlSize = .regular
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectOption(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if context.coordinator.options != options {
            context.coordinator.options = options
            control.segmentCount = options.count
            for (index, option) in options.enumerated() {
                control.setLabel(option.title, forSegment: index)
                control.setEnabled(option.isEnabled, forSegment: index)
            }
        }
        control.selectedSegment = options.firstIndex { $0.id == selection } ?? -1
        control.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsicSize = nsView.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? intrinsicSize.width
        return CGSize(width: max(0, width), height: intrinsicSize.height)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var options: [SettingsPopup.Option] = []

        init(selection: Binding<String>) { self.selection = selection }

        @objc func selectOption(_ sender: NSSegmentedControl) {
            guard options.indices.contains(sender.selectedSegment), options[sender.selectedSegment].isEnabled else { return }
            selection.wrappedValue = options[sender.selectedSegment].id
        }
    }
}

struct AppIconView: View {
    let appURL: URL?
    let symbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let appURL {
                Image(nsImage: AppIconImages.image(for: appURL))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
enum AppIconImages {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func image(for appURL: URL) -> NSImage {
        let appearance = NSApp.effectiveAppearance
        let key = "\(appURL.absoluteString)|\(appearance.name.rawValue)" as NSString
        if let image = cache.object(forKey: key) { return image }

        let source = NSWorkspace.shared.icon(forFile: appURL.path)
        // Resolve the system icon before SwiftUI selects its small-size representation.
        let pixels = 128
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        bitmap.size = NSSize(width: pixels, height: pixels)
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.cgContext.clear(NSRect(origin: .zero, size: bitmap.size))
            source.draw(in: NSRect(origin: .zero, size: bitmap.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        cache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return image
    }

    static func invalidate() { cache.removeAllObjects() }
}

extension View {
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
