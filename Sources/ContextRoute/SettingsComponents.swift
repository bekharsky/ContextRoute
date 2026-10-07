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
            .padding(inset)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AppIconView: View {
    let appURL: URL?
    let symbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
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
