import XCTest
@testable import DotCore

final class ProviderModelCatalogTests: XCTestCase {
    func testFormattedNameHelper() {
        XCTAssertEqual(
            ProviderModelCatalog.formattedName(for: "whisper-large-v3-turbo"),
            "Whisper Large V3 Turbo"
        )
        XCTAssertEqual(
            ProviderModelCatalog.formattedName(for: "distil-whisper-large-v3-en"),
            "Distil Whisper Large V3 (EN)"
        )
        XCTAssertEqual(
            ProviderModelCatalog.formattedName(for: "nova-3"),
            "Nova 3"
        )
        XCTAssertEqual(
            ProviderModelCatalog.formattedName(for: "scribe_v1"),
            "Scribe_v1"
        )
    }

    func testParseOpenAIModelsWithWhisperFilter() {
        let json = """
        {
            "data": [
                { "id": "llama-3.1-8b-instant" },
                { "id": "whisper-large-v3-turbo" },
                { "id": "whisper-large-v3" },
                { "id": "mixtral-8x7b-32768" }
            ]
        }
        """.data(using: .utf8)!

        let parsed = ProviderModelCatalog.parseOpenAIModels(data: json, filterSubstring: "whisper")

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "whisper-large-v3-turbo")
        XCTAssertEqual(parsed[0].name, "Whisper Large V3 Turbo")
        XCTAssertEqual(parsed[1].id, "whisper-large-v3")
        XCTAssertEqual(parsed[1].name, "Whisper Large V3")
    }

    func testParseDeepgramArrayModels() {
        let json = """
        {
            "models": [
                { "name": "nova-3", "canonical_name": "nova-3" },
                { "name": "nova-2", "canonical_name": "nova-2" },
                { "name": "custom-domain-v1", "canonical_name": "custom-domain-v1" }
            ]
        }
        """.data(using: .utf8)!

        let parsed = ProviderModelCatalog.parseDeepgramModels(data: json)

        XCTAssertTrue(parsed.contains { $0.id == "nova-3" })
        XCTAssertTrue(parsed.contains { $0.id == "nova-2" })
        XCTAssertTrue(parsed.contains { $0.id == "custom-domain-v1" })
    }

    func testParseElevenLabsTranscriptionModels() {
        let json = """
        [
            { "model_id": "eleven_multilingual_v2", "name": "Multilingual v2", "can_do_transcription": false },
            { "model_id": "scribe_v1", "name": "Scribe (v1)", "can_do_transcription": true },
            { "model_id": "scribe_v2", "name": "Scribe (v2)", "can_do_transcription": true }
        ]
        """.data(using: .utf8)!

        let parsed = ProviderModelCatalog.parseElevenLabsModels(data: json)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "scribe_v1")
        XCTAssertEqual(parsed[1].id, "scribe_v2")
    }

    func testFetchingWithoutKeyReturnsEmpty() async {
        let models = await ProviderModelCatalog.fetchModels(for: ProviderIdentifier.groq, apiKey: nil)
        XCTAssertTrue(models.isEmpty, "No models before an API key is connected")
    }

    func testXiaomiASRFormattingAndClassification() {
        XCTAssertEqual(
            ProviderModelCatalog.formattedName(for: "mimo-v2.5-asr"),
            "MiMo V2.5 ASR"
        )
        XCTAssertEqual(
            ProviderModelCatalog.modelDetail(for: "mimo-v2.5-asr"),
            "Speech recognition model"
        )
        XCTAssertTrue(ProviderModelCatalog.isSpeechToTextModel("mimo-v2.5-asr"))
        XCTAssertFalse(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.5-asr"))

        // TTS and Chat models must be flagged as non-ASR
        XCTAssertTrue(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.5-tts-voiceclone"))
        XCTAssertTrue(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.5-tts-voicedesign"))
        XCTAssertTrue(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.6-flash"))
        XCTAssertTrue(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.6-pro"))
        XCTAssertTrue(ProviderModelCatalog.isExplicitNonASRModel("mimo-v2.6-pro-ultraspeed"))
    }

    func testOpenAICompatibleFilteringExcludesTTSAndChat() {
        let json = """
        {
            "data": [
                { "id": "mimo-v2.5-asr" },
                { "id": "mimo-v2.5-tts-voiceclone" },
                { "id": "mimo-v2.5-tts-voicedesign" },
                { "id": "mimo-v2.6-flash" },
                { "id": "mimo-v2.6-pro" },
                { "id": "mimo-v2.6-pro-ultraspeed" }
            ]
        }
        """.data(using: .utf8)!

        let parsed = ProviderModelCatalog.parseOpenAIModels(data: json)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "mimo-v2.5-asr")
        XCTAssertEqual(parsed[0].name, "MiMo V2.5 ASR")
        XCTAssertEqual(parsed[0].detail, "Speech recognition model")
    }
}
