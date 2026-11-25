import Foundation

enum AppLanguage: String, CaseIterable {
    case zhHant = "zh-Hant"
    case en = "en"

    static let storageKey = "ipac.interfaceLanguage"

    static var current: AppLanguage { read(from: .standard) }

    static func read(from defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .zhHant
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum L10n {
    private static let mainBundles: [AppLanguage: Bundle] = Dictionary(
        uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            localizedBundle(language, in: .main).map { (language, $0) }
        }
    )

    static func text(_ key: String, language: AppLanguage = .current,
                     bundle: Bundle = .main) -> String {
        let localized = bundle === Bundle.main
            ? mainBundles[language]
            : localizedBundle(language, in: bundle)
        return localized?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    static func format(_ key: String, arguments: [CVarArg],
                       language: AppLanguage = .current, bundle: Bundle = .main) -> String {
        String(format: text(key, language: language, bundle: bundle),
               locale: language.locale, arguments: arguments)
    }

    private static func localizedBundle(_ language: AppLanguage, in bundle: Bundle) -> Bundle? {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
