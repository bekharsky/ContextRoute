import SwiftUI

enum SettingsSection: CaseIterable, Identifiable, Hashable {
    case routes, handlers, settings
    var id: Self { self }
    var key: String {
        switch self {
        case .routes: "App routes"
        case .handlers: "Open in apps"
        case .settings: "Settings"
        }
    }
    var title: LocalizedStringKey { LocalizedStringKey(key) }
    var resolvedTitle: String { ContextRouteLocalization.string(key) }
    var symbol: String {
        switch self {
        case .routes: "arrow.triangle.branch"
        case .handlers: "arrow.up.right.square"
        case .settings: "gearshape"
        }
    }
}

struct SettingsSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let section: SettingsSection
    let anchor: String
    let keywords: String
}

@MainActor
enum SettingsSearchIndex {
    static func results(for query: String, model: RouterModel, browsers: [BrowserInfo]) -> [SettingsSearchResult] {
        var entries = SettingsSection.allCases.map {
            SettingsSearchResult(id: $0.key, title: $0.resolvedTitle, section: $0, anchor: "top", keywords: $0.key)
        }
        let preferences: [(String, String, String)] = [
            ("Fallback browser", "fallback", "browser default fallback резервный браузер браузер по умолчанию " + browsers.map(\.name).joined(separator: " ")),
            ("Appearance", "appearance", "theme appearance system light dark тема внешний вид светлая тёмная системная"),
            ("Language", "language", "language english russian язык английский русский"),
            ("Launch at login", "login", "startup login launch автозапуск вход запуск"),
            ("Import and export", "transfer", "backup settings import export резервная копия импорт экспорт настройки")
        ]
        entries += preferences.map { key, anchor, words in
            SettingsSearchResult(id: anchor, title: ContextRouteLocalization.string(key), section: .settings, anchor: anchor, keywords: words)
        }
        entries.append(SettingsSearchResult(id: "check", title: ContextRouteLocalization.string("Check route"), section: .routes,
            anchor: "check", keywords: "check preview link url routing проверить ссылку маршрут"))
        entries += model.sourceRoutes.map { route in
            SettingsSearchResult(id: route.id.uuidString, title: route.sourceName, section: .routes, anchor: route.id.uuidString,
                keywords: [route.sourceBundleIdentifier, route.browserName, route.profileName ?? "", "app routes правила приложения"].joined(separator: " "))
        }
        entries += model.urlAppOverrides.map { item in
            SettingsSearchResult(id: item.id, title: item.name, section: .handlers, anchor: item.id,
                keywords: item.matchSummary + " handlers redirects приложения обработчики переадресация")
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.section.resolvedTitle) \(entry.keywords)".lowercased()
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.sorted { lhs, rhs in
            let left = lhs.title.localizedCaseInsensitiveContains(query)
            let right = rhs.title.localizedCaseInsensitiveContains(query)
            if left != right { return left }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
