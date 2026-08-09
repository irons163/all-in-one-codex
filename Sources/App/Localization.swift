import Foundation

/// The languages this app ships localizations for. Unsupported system
/// languages deliberately fall back to English (the development language).
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"

    /// Resolves a concrete app language from a locale, including the script
    /// disambiguation for Chinese. Unknown languages resolve to English.
    static func resolve(from locale: Locale) -> AppLanguage {
        let language = locale.language.languageCode?.identifier.lowercased()
        let script = locale.language.script?.identifier
        switch (language, script) {
        case ("en", _):
            return .english
        case ("zh", "Hant"):
            return .traditionalChinese
        case ("zh", "Hans"):
            return .simplifiedChinese
        case ("zh", _):
            return .traditionalChinese
        case ("fr", _):
            return .french
        case ("es", _):
            return .spanish
        case ("ja", _):
            return .japanese
        case ("ko", _):
            return .korean
        default:
            return .english
        }
    }

    /// The best supported language for the current system locale. When the
    /// system language is not in the supported list this is `.english`.
    static var current: AppLanguage {
        let supported = Set(allCases.map(\.rawValue))
        let preferred = Bundle.main.preferredLocalizations.first {
            supported.contains($0)
        }
        return preferred.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

/// Localized string lookup used by non-SwiftUI code (status messages, errors,
/// computed labels). Keys are the original source strings so they share the
/// same `Localizable.strings` tables as SwiftUI's automatic lookup.
enum L10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
