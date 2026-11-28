import Foundation

@main
struct AppLanguageTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let suiteName = "com.henge.tests.language.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expect(AppLanguage.read(from: defaults) == .zhHant, "New installs use Traditional Chinese")
        defaults.set("unsupported-language", forKey: AppLanguage.storageKey)
        expect(AppLanguage.read(from: defaults) == .zhHant, "Unknown preferences fall back to Chinese")
        defaults.set(42, forKey: AppLanguage.storageKey)
        expect(AppLanguage.read(from: defaults) == .zhHant, "Invalid preferences do not crash")
        for language in AppLanguage.allCases {
            language.save(to: defaults)
            expect(AppLanguage.read(from: defaults) == language, "The language choice persists")
            expect(defaults.string(forKey: AppLanguage.storageKey) == language.rawValue,
                   "Storage uses stable language identifiers")
        }
        expect(AppLanguage.zhHant.locale.identifier == "zh-Hant", "Chinese locale is explicit")
        expect(AppLanguage.en.locale.identifier == "en", "English locale is explicit")
        expect(L10n.text("nonlocalized technical ID", language: .en) == "nonlocalized technical ID",
               "Unknown keys retain their original value")
        expect(L10n.format("literal 100%% %@", arguments: ["value"], language: .en)
               == "literal 100% value", "Fallback formatting preserves escaped percent signs")
        expect(L10n.format("%2$@ / %1$@", arguments: ["first", "second"], language: .en)
               == "second / first", "Translators can reorder placeholders")
        expect(L10n.format("%.2f", arguments: [1.25], language: .en) == "1.25",
               "Formatting uses the selected locale")

        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the compiled localization bundle as the only argument")
        }
        for language in AppLanguage.allCases {
            expect(bundle.path(forResource: language.rawValue, ofType: "lproj") != nil,
                   "Both language resources are compiled")
        }
        expect(L10n.text("介面語言", language: .zhHant, bundle: bundle) == "介面語言",
               "The Chinese catalog resolves independently of the host language")
        let english = L10n.text("介面語言", language: .en, bundle: bundle)
        expect(english != "介面語言" && !english.isEmpty, "The English catalog is actually loaded")
        expect(L10n.text("介面語言", language: .zhHant, bundle: bundle) == "介面語言",
               "Switching back does not reuse a stale English bundle")
        expect(L10n.text("missing catalog key", language: .en, bundle: bundle) == "missing catalog key",
               "Missing translations preserve the original label")
        let failure = "file not found: My App.app"
        let translatedFailure = L10n.format("無法開啟：%@", arguments: [failure],
                                           language: .en, bundle: bundle)
        expect(!translatedFailure.hasPrefix("無法開啟") && translatedFailure.contains(failure),
               "Dynamic error labels translate while preserving raw technical details")
        expect(L10n.format("無法開啟：%@", arguments: [failure], language: .zhHant, bundle: bundle)
               == "無法開啟：\(failure)", "Dynamic error labels can switch back to Chinese")
        let compactKey = "JIT 中繼資料緊湊儲存（實驗性）"
        expect(L10n.text(compactKey, language: .en, bundle: bundle) != compactKey,
               "The compact JIT preference has a real English translation")
        let sillKey = "已切換為 Sill 多指觸控板模式"
        expect(L10n.text(sillKey, language: .en, bundle: bundle) != sillKey,
               "Sill touch mode toast has a real English translation")
        let imeKey = "中/英 IME"
        expect(L10n.text(imeKey, language: .en, bundle: bundle) == "EN/IME",
               "Sill IME button translates to EN/IME")

        print("App language: \(checks) checks passed")
    }
}
