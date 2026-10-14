import SwiftUI

struct RouteCheckerView: View {
    @ObservedObject var model: RouterModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var source = ""

    private var parsedURL: URL? {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check route").font(.title2.weight(.semibold))
            SectionIntro("See where a link will go and why. Checking a route does not open the link.")
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("https://example.com", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Link to check")
                    Picker("Source app", selection: $source) {
                        Text("Unknown app").tag("")
                        ForEach(model.sourceRoutes) { route in
                            Text(route.sourceName).tag(route.sourceBundleIdentifier)
                        }
                    }
                    if !link.isEmpty && parsedURL == nil {
                        Text("Enter a complete http or https link.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let url = parsedURL {
                let result = model.decision(for: url, sourceBundleIdentifier: source.isEmpty ? nil : source)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(result.kindName).font(.caption).foregroundStyle(.secondary)
                        Text(result.targetName.isEmpty ? result.explanation.text : result.targetName).font(.headline)
                        if !result.targetName.isEmpty { Text(result.explanation.text).font(.callout).foregroundStyle(.secondary) }
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Priority: Website routes → Open in apps → App routes → Fallback browser")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}
