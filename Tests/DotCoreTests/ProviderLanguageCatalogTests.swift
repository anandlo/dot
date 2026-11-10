import XCTest
@testable import DotCore

final class ProviderLanguageCatalogTests: XCTestCase {
    func testWhisperLanguages() {
        let languages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.openAI, model: "whisper-1")
        XCTAssertFalse(languages.isEmpty)
        XCTAssertEqual(languages.first?.id, "auto")
        XCTAssertTrue(languages.contains(where: { $0.id == "en" }))
        XCTAssertTrue(languages.contains(where: { $0.id == "zh" }))
        XCTAssertTrue(languages.contains(where: { $0.id == "es" }))
        XCTAssertTrue(languages.contains(where: { $0.id == "ja" }))
    }

    func testEnglishOnlyModelsRestrictLanguages() {
        let distilLanguages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.groq, model: "distil-whisper-large-v3-en")
        XCTAssertEqual(distilLanguages.count, 1)
        XCTAssertEqual(distilLanguages[0].id, "en")
        XCTAssertEqual(distilLanguages[0].name, "English")

        let turboLanguages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.groq, model: "whisper-large-v3-turbo")
        XCTAssertGreaterThan(turboLanguages.count, 10)
        XCTAssertTrue(turboLanguages.contains(where: { $0.id == "auto" }))
    }

    func testAzureLanguages() {
        let azureLanguages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.azure, model: nil)
        XCTAssertFalse(azureLanguages.isEmpty)
        XCTAssertEqual(azureLanguages.first?.id, "auto")
        XCTAssertTrue(azureLanguages.contains(where: { $0.id == "en-US" }))
        XCTAssertTrue(azureLanguages.contains(where: { $0.id == "zh-CN" }))
        XCTAssertTrue(azureLanguages.contains(where: { $0.id == "de-DE" }))
    }

    func testDeepgramLanguages() {
        let languages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.deepgram, model: "nova-3")
        XCTAssertFalse(languages.isEmpty)
        XCTAssertEqual(languages.first?.id, "auto")
        XCTAssertTrue(languages.contains(where: { $0.id == "en" }))
        XCTAssertTrue(languages.contains(where: { $0.id == "es" }))
    }

    func testXiaomiLanguages() {
        let languages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.xiaomi, model: nil)
        XCTAssertFalse(languages.isEmpty)
        XCTAssertEqual(languages.first?.id, "auto")
        XCTAssertTrue(languages.contains(where: { $0.id == "zh" }))
        XCTAssertTrue(languages.contains(where: { $0.id == "en" }))
    }

    func testAppleLanguagesDynamicLocales() {
        let languages = ProviderLanguageCatalog.languages(for: ProviderIdentifier.apple, model: nil)
        XCTAssertGreaterThan(languages.count, 1)
        XCTAssertEqual(languages.first?.id, "auto")
    }

    func testValidatedLanguageFallback() {
        // When switching to English-only model, non-English fallback to "en"
        let fallbackEn = ProviderLanguageCatalog.validatedLanguage("zh", for: ProviderIdentifier.groq, model: "distil-whisper-large-v3-en")
        XCTAssertEqual(fallbackEn, "en")

        // Auto fallback to "en" when auto is not in list
        let autoFallback = ProviderLanguageCatalog.validatedLanguage("auto", for: ProviderIdentifier.groq, model: "distil-whisper-large-v3-en")
        XCTAssertEqual(autoFallback, "en")

        // Supported language is preserved
        let preservedZh = ProviderLanguageCatalog.validatedLanguage("zh", for: ProviderIdentifier.groq, model: "whisper-large-v3")
        XCTAssertEqual(preservedZh, "zh")

        // Auto is preserved when provider supports auto
        let preservedAuto = ProviderLanguageCatalog.validatedLanguage(nil, for: ProviderIdentifier.openAI, model: "whisper-1")
        XCTAssertEqual(preservedAuto, "auto")

        // Prefix matching (e.g. "en" matches "en-US" for Azure)
        let matchedLocale = ProviderLanguageCatalog.validatedLanguage("en", for: ProviderIdentifier.azure, model: nil)
        XCTAssertEqual(matchedLocale, "en-US")
    }

    func testMenuLanguagesConversion() {
        let menuLangs = ProviderLanguageCatalog.menuLanguages(for: ProviderIdentifier.openAI, model: nil)
        XCTAssertFalse(menuLangs.isEmpty)
        XCTAssertEqual(menuLangs.first?.id, "auto")
        XCTAssertEqual(menuLangs.first?.name, "Auto-detect")
    }
}
