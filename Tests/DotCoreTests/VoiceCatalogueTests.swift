import XCTest

@testable import DotCore

/// A catalogue is only useful if the best voice is at the top and a listing that
/// half-parses still shows what it could read. These tests cover the ordering
/// promise and the three list shapes Dot accepts from vendors.
final class VoiceCatalogueTests: XCTestCase {
    private func voice(
        _ id: String,
        _ quality: VoiceDescriptor.QualityTier,
        language: String = "en-US",
        name: String? = nil
    ) -> VoiceDescriptor {
        VoiceDescriptor(
            providerID: "test",
            id: id,
            name: name ?? id,
            language: language,
            quality: quality
        )
    }

    func testPremiumAndEnhancedComeFirst() {
        let voices = [
            voice("default", .standard),
            voice("enhanced", .enhanced),
            voice("premium", .premium),
            voice("personal", .personal),
            voice("unknown", .unknown),
        ]
        let ordered = VoiceCatalogue.select(voices, locale: "en-US")
        XCTAssertEqual(ordered.map(\.id), ["premium", "personal", "enhanced", "default", "unknown"])
    }

    func testTheLocaleMatchSortsFirstWithinATier() {
        let voices = [
            voice("british", .enhanced, language: "en-GB", name: "A"),
            voice("american", .enhanced, language: "en-US", name: "B"),
        ]
        XCTAssertEqual(VoiceCatalogue.select(voices, locale: "en-US").map(\.id), ["american", "british"])
    }

    func testAQualityFloorFiltersTheLowerTiers() {
        let voices = [voice("default", .standard), voice("enhanced", .enhanced), voice("premium", .premium)]
        XCTAssertEqual(VoiceCatalogue.select(voices, floor: .enhanced).map(\.id), ["premium", "enhanced"])
        XCTAssertEqual(VoiceCatalogue.select(voices, floor: .premium).map(\.id), ["premium"])
        XCTAssertEqual(VoiceCatalogue.select(voices, floor: .standard).count, 3)
    }

    func testALanguageFilterKeepsMultilingualVoices() {
        let voices = [
            voice("english", .enhanced, language: "en-US"),
            voice("german", .enhanced, language: "de-DE"),
            voice("multi", .premium, language: "multi"),
        ]
        XCTAssertEqual(VoiceCatalogue.select(voices, language: "en").map(\.id), ["multi", "english"])
    }

    func testLanguageTagsAreComparedWithoutCaseOrUnderscores() {
        XCTAssertEqual(VoiceCatalogue.normalizedLanguage("EN_us"), "en-us")
        XCTAssertEqual(VoiceCatalogue.normalizedLanguage(nil), "")
        XCTAssertEqual(VoiceCatalogue.normalizedLanguage(" en-GB "), "en-gb")
    }

    // MARK: - Parsers

    func testElevenLabsListKeepsUntaggedClonedVoices() throws {
        let json = """
        {"voices":[
          {"voice_id":"v1","name":"Narrator","category":"cloned","labels":{"language":"en-GB"}},
          {"voice_id":"v2","name":"Untagged","category":"premade"},
          {"name":"no id"}
        ]}
        """
        let voices = try ElevenLabsVoiceParser.catalogue(in: Data(json.utf8))
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(voices[0].id, "v1")
        XCTAssertEqual(voices[0].language, "en-GB")
        XCTAssertEqual(voices[0].quality, .premium)
        XCTAssertEqual(voices[1].id, "v2")
        XCTAssertEqual(voices[1].quality, .enhanced)
        XCTAssertEqual(voices[1].language, "multi")
    }

    func testElevenLabsRejectsSomethingThatIsNotJSON() {
        XCTAssertThrowsError(try ElevenLabsVoiceParser.catalogue(in: Data("<html>".utf8)))
    }

    func testCartesiaAcceptsBothListShapes() throws {
        let bare = """
        [{"id":"voice-1","name":"Reader","language":"en","is_public":true}]
        """
        let paged = """
        {"data":[{"id":"voice-2","name":"Mine","description":"Warm"}]}
        """
        let first = try CartesiaVoiceParser.catalogue(in: Data(bare.utf8))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].quality, .enhanced)
        XCTAssertEqual(first[0].language, "en")
        let second = try CartesiaVoiceParser.catalogue(in: Data(paged.utf8))
        XCTAssertEqual(second[0].id, "voice-2")
        XCTAssertEqual(second[0].quality, .premium)
        XCTAssertEqual(second[0].detail, "Warm")
    }

    func testAzureKeepsOnlyNeuralVoicesAndReadsTheLocale() throws {
        let json = """
        [
          {"ShortName":"en-US-JennyNeural","DisplayName":"Jenny","Locale":"en-US","VoiceType":"Neural","Gender":"Female"},
          {"ShortName":"en-US-Jenny","DisplayName":"Legacy Jenny","Locale":"en-US","VoiceType":"Standard"},
          {"ShortName":"en-US-AvaNeuralHD","DisplayName":"Ava HD","Locale":"en-US","VoiceType":"Neural","StyleList":["cheerful","sad"]},
          {"ShortName":"de-DE-KatjaNeural","DisplayName":"Katja","VoiceType":"Neural"}
        ]
        """
        let voices = try AzureVoiceParser.catalogue(in: Data(json.utf8))
        XCTAssertEqual(voices.map(\.id), ["en-US-JennyNeural", "en-US-AvaNeuralHD", "de-DE-KatjaNeural"])
        XCTAssertEqual(voices[0].language, "en-US")
        XCTAssertEqual(voices[0].quality, .enhanced)
        XCTAssertEqual(voices[1].quality, .premium)
        XCTAssertEqual(voices[1].detail, "Styles: cheerful, sad")
        XCTAssertEqual(voices[2].language, "de-DE", "a missing locale is read from the voice id")
    }

    func testTheShippedCataloguesAreOrderedAndComplete() async throws {
        let openAI = try await OpenAIVoiceProvider(apiKey: nil).voices(language: nil)
        XCTAssertEqual(openAI.count, 13)
        XCTAssertEqual(Set(openAI.map(\.language)), ["multi"])
        XCTAssertEqual(Set(openAI.map(\.id)).count, 13)
        XCTAssertTrue(openAI.contains { $0.id == "marin" })
        XCTAssertTrue(openAI.contains { $0.id == "cedar" })
        XCTAssertEqual(
            openAI.map(\.quality.rank),
            openAI.map(\.quality.rank).sorted(by: >)
        )

        let deepgram = try await DeepgramVoiceProvider(apiKey: nil).voices(language: "en")
        XCTAssertEqual(deepgram.count, 5)
        XCTAssertTrue(deepgram.contains { $0.id == "aura-2-thalia-en" })
        XCTAssertEqual(DeepgramVoiceProvider.defaultModel, "aura-2-thalia-en")
        XCTAssertEqual(DeepgramVoiceProvider.languageSuffix(of: "aura-2-draco-en"), "en")
        XCTAssertEqual(DeepgramVoiceProvider.languageSuffix(of: "no-suffix"), "multi")
    }

    func testTheOnDeviceCatalogueIsOrderedWithPremiumFirst() async throws {
        let voices = try await AppleVoiceProvider().voices(language: nil)
        let ranks = voices.map(\.quality.rank)
        XCTAssertEqual(ranks, ranks.sorted(by: >), "the picker must offer the best voice first")
    }
}
