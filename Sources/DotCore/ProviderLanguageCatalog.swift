import Foundation
import Speech

/// A spoken language offered by a speech provider.
public struct AvailableLanguage: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// The spoken languages each provider and model can be asked for.
///
/// A provider refuses or silently ignores a language it does not implement, so
/// every list here is the set the provider actually honours. `auto` is an
/// absence of a choice, not a language: the provider resolves it to its own
/// detection or to the Mac's language.
public enum ProviderLanguageCatalog {
    /// Whisper's multilingual set, as ISO-639-1 tags, with detection.
    public static let whisperLanguages: [AvailableLanguage] = [
        AvailableLanguage(id: "auto", name: "Auto-detect", detail: "Automatically detects the spoken language"),
        AvailableLanguage(id: "en", name: "English"),
        AvailableLanguage(id: "zh", name: "Chinese (Mandarin)"),
        AvailableLanguage(id: "es", name: "Spanish"),
        AvailableLanguage(id: "fr", name: "French"),
        AvailableLanguage(id: "de", name: "German"),
        AvailableLanguage(id: "ja", name: "Japanese"),
        AvailableLanguage(id: "ko", name: "Korean"),
        AvailableLanguage(id: "it", name: "Italian"),
        AvailableLanguage(id: "pt", name: "Portuguese"),
        AvailableLanguage(id: "ru", name: "Russian"),
        AvailableLanguage(id: "hi", name: "Hindi"),
        AvailableLanguage(id: "ar", name: "Arabic"),
        AvailableLanguage(id: "nl", name: "Dutch"),
        AvailableLanguage(id: "pl", name: "Polish"),
        AvailableLanguage(id: "tr", name: "Turkish"),
        AvailableLanguage(id: "sv", name: "Swedish"),
        AvailableLanguage(id: "id", name: "Indonesian"),
        AvailableLanguage(id: "vi", name: "Vietnamese"),
        AvailableLanguage(id: "uk", name: "Ukrainian"),
        AvailableLanguage(id: "el", name: "Greek"),
        AvailableLanguage(id: "cs", name: "Czech"),
        AvailableLanguage(id: "he", name: "Hebrew"),
        AvailableLanguage(id: "da", name: "Danish"),
        AvailableLanguage(id: "fi", name: "Finnish"),
        AvailableLanguage(id: "no", name: "Norwegian"),
        AvailableLanguage(id: "th", name: "Thai"),
        AvailableLanguage(id: "hu", name: "Hungarian"),
        AvailableLanguage(id: "ro", name: "Romanian"),
        AvailableLanguage(id: "ms", name: "Malay"),
    ]

    /// The one language an English-only model accepts.
    public static let englishOnlyLanguages: [AvailableLanguage] = [
        AvailableLanguage(id: "en", name: "English", detail: "This model only supports English transcription"),
    ]

    /// Azure's BCP-47 locales, with multi-language detection.
    public static let azureLanguages: [AvailableLanguage] = [
        AvailableLanguage(id: "auto", name: "Auto-detect", detail: "Azure Speech multi-language detection"),
        AvailableLanguage(id: "en-US", name: "English (United States)"),
        AvailableLanguage(id: "en-GB", name: "English (United Kingdom)"),
        AvailableLanguage(id: "zh-CN", name: "Chinese (Mandarin, Simplified)"),
        AvailableLanguage(id: "zh-TW", name: "Chinese (Taiwan)"),
        AvailableLanguage(id: "zh-HK", name: "Chinese (Cantonese)"),
        AvailableLanguage(id: "es-ES", name: "Spanish (Spain)"),
        AvailableLanguage(id: "es-MX", name: "Spanish (Mexico)"),
        AvailableLanguage(id: "fr-FR", name: "French (France)"),
        AvailableLanguage(id: "fr-CA", name: "French (Canada)"),
        AvailableLanguage(id: "de-DE", name: "German (Germany)"),
        AvailableLanguage(id: "it-IT", name: "Italian (Italy)"),
        AvailableLanguage(id: "ja-JP", name: "Japanese (Japan)"),
        AvailableLanguage(id: "ko-KR", name: "Korean (Korea)"),
        AvailableLanguage(id: "pt-BR", name: "Portuguese (Brazil)"),
        AvailableLanguage(id: "pt-PT", name: "Portuguese (Portugal)"),
        AvailableLanguage(id: "ru-RU", name: "Russian (Russia)"),
        AvailableLanguage(id: "hi-IN", name: "Hindi (India)"),
        AvailableLanguage(id: "ar-SA", name: "Arabic (Saudi Arabia)"),
        AvailableLanguage(id: "nl-NL", name: "Dutch (Netherlands)"),
        AvailableLanguage(id: "pl-PL", name: "Polish (Poland)"),
        AvailableLanguage(id: "sv-SE", name: "Swedish (Sweden)"),
        AvailableLanguage(id: "tr-TR", name: "Turkish (Turkey)"),
        AvailableLanguage(id: "id-ID", name: "Indonesian (Indonesia)"),
        AvailableLanguage(id: "vi-VN", name: "Vietnamese (Vietnam)"),
        AvailableLanguage(id: "uk-UA", name: "Ukrainian (Ukraine)"),
        AvailableLanguage(id: "da-DK", name: "Danish (Denmark)"),
        AvailableLanguage(id: "fi-FI", name: "Finnish (Finland)"),
        AvailableLanguage(id: "nb-NO", name: "Norwegian (Bokmål)"),
        AvailableLanguage(id: "th-TH", name: "Thai (Thailand)"),
        AvailableLanguage(id: "cs-CZ", name: "Czech (Czechia)"),
        AvailableLanguage(id: "el-GR", name: "Greek (Greece)"),
        AvailableLanguage(id: "he-IL", name: "Hebrew (Israel)"),
    ]

    /// Deepgram's speech recognition languages.
    public static let deepgramLanguages: [AvailableLanguage] = [
        AvailableLanguage(id: "auto", name: "Auto-detect", detail: "Deepgram multi-language detect"),
        AvailableLanguage(id: "en", name: "English"),
        AvailableLanguage(id: "en-US", name: "English (US)"),
        AvailableLanguage(id: "en-GB", name: "English (UK)"),
        AvailableLanguage(id: "en-AU", name: "English (Australia)"),
        AvailableLanguage(id: "en-IN", name: "English (India)"),
        AvailableLanguage(id: "es", name: "Spanish"),
        AvailableLanguage(id: "es-419", name: "Spanish (Latin America)"),
        AvailableLanguage(id: "fr", name: "French"),
        AvailableLanguage(id: "fr-CA", name: "French (Canada)"),
        AvailableLanguage(id: "de", name: "German"),
        AvailableLanguage(id: "hi", name: "Hindi"),
        AvailableLanguage(id: "ja", name: "Japanese"),
        AvailableLanguage(id: "ko", name: "Korean"),
        AvailableLanguage(id: "pt", name: "Portuguese"),
        AvailableLanguage(id: "pt-BR", name: "Portuguese (Brazil)"),
        AvailableLanguage(id: "ru", name: "Russian"),
        AvailableLanguage(id: "zh", name: "Chinese"),
        AvailableLanguage(id: "zh-CN", name: "Chinese (Mandarin)"),
        AvailableLanguage(id: "zh-TW", name: "Chinese (Taiwan)"),
        AvailableLanguage(id: "it", name: "Italian"),
        AvailableLanguage(id: "nl", name: "Dutch"),
        AvailableLanguage(id: "sv", name: "Swedish"),
        AvailableLanguage(id: "tr", name: "Turkish"),
        AvailableLanguage(id: "id", name: "Indonesian"),
        AvailableLanguage(id: "uk", name: "Ukrainian"),
        AvailableLanguage(id: "pl", name: "Polish"),
        AvailableLanguage(id: "da", name: "Danish"),
        AvailableLanguage(id: "no", name: "Norwegian"),
    ]

    /// The languages Xiaomi ASR honours.
    ///
    /// The list is exactly what ``XiaomiASRProvider/namedLanguage(_:)`` sends:
    /// a tag it does not name is dropped from the request and the model falls
    /// back to its own default, so offering one here would change nothing but
    /// the menu. `auto` is the absence of a hint, which the provider resolves
    /// to the Mac's own language when it can name it.
    public static let xiaomiLanguages: [AvailableLanguage] = [
        AvailableLanguage(id: "auto", name: "Auto-detect", detail: "Auto speech detection"),
        AvailableLanguage(id: "zh", name: "中文 (Mandarin)"),
        AvailableLanguage(id: "en", name: "English"),
    ]

    /// The locales the on-device transcriber supports on this Mac.
    ///
    /// The list is read from the system at call time: it differs between
    /// machines and changes when macOS installs another language asset.
    ///
    /// - Returns: detection first, then the supported locales by name.
    public static func appleLanguages() -> [AvailableLanguage] {
        var list: [AvailableLanguage] = [
            AvailableLanguage(id: "auto", name: "Auto-detect", detail: "System default speech language")
        ]
        let locales = SFSpeechRecognizer.supportedLocales()
        var items: [AvailableLanguage] = []
        for locale in locales {
            let id = locale.identifier
            guard !id.contains("translit") else { continue }
            let name = Locale.current.localizedString(forIdentifier: id) ?? id
            items.append(AvailableLanguage(id: id, name: name))
        }
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        list.append(contentsOf: items)
        return list
    }

    /// The languages a provider and model accept.
    ///
    /// The model narrows the list: an English-only model accepts English and
    /// nothing else, whatever the provider supports in general.
    ///
    /// - Parameters:
    ///   - providerID: the provider.
    ///   - model: the configured model, or `nil` for the provider's default.
    /// - Returns: the languages to offer, `auto` first where the provider
    ///   detects.
    public static func languages(for providerID: String, model: String? = nil) -> [AvailableLanguage] {
        switch providerID {
        case ProviderIdentifier.apple:
            return appleLanguages()
        case ProviderIdentifier.groq:
            if let model = model?.lowercased(), model.contains("-en") {
                return englishOnlyLanguages
            }
            return whisperLanguages
        case ProviderIdentifier.azure:
            return azureLanguages
        case ProviderIdentifier.deepgram:
            return deepgramLanguages
        case ProviderIdentifier.xiaomi:
            return xiaomiLanguages
        case ProviderIdentifier.elevenLabs:
            return whisperLanguages
        case ProviderIdentifier.openAI:
            return whisperLanguages
        default:
            return whisperLanguages
        }
    }

    /// The language to keep after a provider or model change.
    ///
    /// A stored language is preserved when the new provider accepts it, matched
    /// by prefix when the tags differ in region (`en` against `en-US`), and
    /// replaced by the provider's first offered language when it does not.
    ///
    /// - Parameters:
    ///   - currentLanguage: the stored tag, or `nil` when nothing was stored.
    ///   - providerID: the provider being switched to.
    ///   - model: the configured model, or `nil` for the provider's default.
    /// - Returns: a tag that appears in ``languages(for:model:)``.
    public static func validatedLanguage(
        _ currentLanguage: String?,
        for providerID: String,
        model: String?
    ) -> String {
        let supported = languages(for: providerID, model: model)
        let current = currentLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty || current.lowercased() == "auto" {
            if supported.contains(where: { $0.id == "auto" }) {
                return "auto"
            }
            return supported.first?.id ?? "en"
        }
        if supported.contains(where: { $0.id == current }) {
            return current
        }
        // A region-qualified tag and a bare language are the same language.
        if let match = supported.first(where: {
            $0.id.lowercased().hasPrefix(current.lowercased()) ||
            current.lowercased().hasPrefix($0.id.lowercased())
        }) {
            return match.id
        }
        return supported.first?.id ?? "auto"
    }

    /// The language rows the menu bar menu shows.
    ///
    /// - Parameters:
    ///   - providerID: the provider.
    ///   - model: the configured model, or `nil` for the provider's default.
    public static func menuLanguages(for providerID: String, model: String?) -> [MenuLanguage] {
        languages(for: providerID, model: model).map {
            MenuLanguage(id: $0.id, name: $0.name)
        }
    }
}
