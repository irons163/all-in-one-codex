import Combine
import Foundation
import SwiftUI

private final class LocalizationBundleToken: NSObject {}

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

    /// The app bundle that actually contains `*.lproj`. `Bundle.main` can be
    /// the test bundle, or can resolve the development language against the
    /// system locale instead of the in-app language picker.
    private static let resourceBundle = Bundle(for: LocalizationBundleToken.self)

    private static let missingValue = "⟦all-in-one.missing⟧"

    fileprivate var localizationBundle: Bundle? {
        let bundle = Self.resourceBundle
        if let url = bundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: rawValue
        ) {
            return Bundle(url: url.deletingLastPathComponent())
        }
        if let path = bundle.path(forResource: rawValue, ofType: "lproj") {
            return Bundle(path: path)
        }
        return nil
    }

    func localizedString(forKey key: String) -> String {
        if let localized = lookup(key, in: localizationBundle) {
            return localized
        }
        if self != .english, let localized = lookup(key, in: AppLanguage.english.localizationBundle) {
            return localized
        }
        return key
    }

    private func lookup(_ key: String, in bundle: Bundle?) -> String? {
        guard let bundle else {
            return nil
        }
        let localized = bundle.localizedString(
            forKey: key,
            value: Self.missingValue,
            table: nil
        )
        return localized == Self.missingValue ? nil : localized
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
    ///
    /// `Bundle.preferredLocalizations` can return the development language for
    /// a standalone app even when macOS is using a supported script variant
    /// (for example `zh-TW`/`zh-Hant`). Resolve the user's preferred locale
    /// directly so the first launch uses the same language as the system.
    static var current: AppLanguage {
        for preferredLanguage in Locale.preferredLanguages {
            let locale = Locale(identifier: preferredLanguage)
            let resolved = resolve(from: locale)
            let languageCode = locale.language.languageCode?.identifier.lowercased()
            if resolved != .english || languageCode == "en" {
                return resolved
            }
        }
        return resolve(from: Locale.current)
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

extension View {
    /// Pins SwiftUI's locale to the in-app language and rebuilds the tree so
    /// views that call `L10n.tr` without reading `AppSettings` still refresh.
    func applyingAppLanguage(_ language: AppLanguage) -> some View {
        self
            .environment(\.locale, language.locale)
            .id(language)
    }
}
