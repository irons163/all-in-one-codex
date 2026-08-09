import Combine
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

    var displayName: String {
        switch self {
        case .english:
            return L10n.tr("English")
        case .traditionalChinese:
            return L10n.tr("Traditional Chinese")
        case .simplifiedChinese:
            return L10n.tr("Simplified Chinese")
        case .french:
            return L10n.tr("French")
        case .spanish:
            return L10n.tr("Spanish")
        case .japanese:
            return L10n.tr("Japanese")
        case .korean:
            return L10n.tr("Korean")
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    private var localizationBundle: Bundle {
        guard
            let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return Bundle.main
        }
        return bundle
    }

    func localizedString(forKey key: String) -> String {
        let localized = localizationBundle.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
        if localized != key || self == .english {
            return localized
        }
        return AppLanguage.english.localizationBundle.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
    }

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

enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system:
            return L10n.tr("Follow System")
        case .light:
            return L10n.tr("Light")
        case .dark:
            return L10n.tr("Dark")
        }
    }
}

enum AppSettingsKey {
    static let language = "allInOneCodex.language"
    static let appearance = "allInOneCodex.appearance"
}

@MainActor
final class AppSettings: ObservableObject {
    static let languageKey = AppSettingsKey.language
    static let appearanceKey = AppSettingsKey.appearance

    private let defaults: UserDefaults

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = defaults.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.current
        self.appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .system
    }
}

/// Localized string lookup used by non-SwiftUI code (status messages, errors,
/// computed labels). Keys are the original source strings so they share the
/// same `Localizable.strings` tables as SwiftUI's automatic lookup.
enum L10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let language = UserDefaults.standard.string(forKey: AppSettingsKey.language)
            .flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.current
        let format = language.localizedString(forKey: key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: args)
    }
}
