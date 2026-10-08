import Foundation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    case system

    static let defaultsKey = "app.contextroute.language"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en")
        case .russian: Locale(identifier: "ru")
        case .system: Locale.current
        }
    }

    static var current: InterfaceLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else { return .english }
        return InterfaceLanguage(rawValue: rawValue) ?? .english
    }
}

enum ContextRouteLocalization {
    static var locale: Locale { InterfaceLanguage.current.locale }

    static func string(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, arguments: [String] = []) -> String {
        let format = string(key)
        return String(
            format: format,
            locale: locale,
            arguments: arguments.map { $0 as CVarArg })
    }

    private static var localizedBundle: Bundle {
        let language = InterfaceLanguage.current
        let identifier: String
        switch language {
        case .english: identifier = "en"
        case .russian: identifier = "ru"
        case .system: identifier = locale.language.languageCode?.identifier ?? "en"
        }
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

struct LocalizedMessage: Sendable {
    let key: String
    var arguments: [String] = []

    var text: String {
        ContextRouteLocalization.format(key, arguments: arguments)
    }
}
