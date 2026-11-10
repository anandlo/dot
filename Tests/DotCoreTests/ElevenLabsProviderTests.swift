import XCTest
@testable import DotCore

final class ElevenLabsProviderTests: XCTestCase {
    func testElevenLabsProviderPropertiesAndDefaults() {
        let provider = ElevenLabsProvider()
        XCTAssertEqual(provider.id, "elevenlabs")
        XCTAssertEqual(provider.displayName, "ElevenLabs")
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 30)
        XCTAssertEqual(ElevenLabsProvider.defaultModel, "scribe_v2")
        XCTAssertEqual(ElevenLabsProvider.defaultBaseURL, URL(string: "https://api.elevenlabs.io/v1")!)
        XCTAssertFalse(provider.tagAudioEvents)
        XCTAssertFalse(provider.noVerbatim)
        XCTAssertFalse(provider.diarize)
        XCTAssertNil(provider.numSpeakers)
        XCTAssertFalse(provider.detectSpeakerRoles)
        XCTAssertFalse(provider.useSpeakerLibrary)
        XCTAssertEqual(provider.timestampsGranularity, "word")
        XCTAssertNil(provider.entityDetection)
        XCTAssertNil(provider.keyterms)
        XCTAssertNil(provider.transcriptEdit)
        XCTAssertTrue(provider.zeroDataRetention)
    }

    func testSupportedModelsAndGranularities() {
        XCTAssertFalse(ElevenLabsProvider.supportedModels.isEmpty)
        XCTAssertTrue(ElevenLabsProvider.supportedModels.contains { $0.id == "scribe_v2" })
        XCTAssertTrue(ElevenLabsProvider.supportedModels.contains { $0.id == "scribe_v1" })

        XCTAssertFalse(ElevenLabsProvider.granularityOptions.isEmpty)
        XCTAssertTrue(ElevenLabsProvider.granularityOptions.contains { $0.id == "word" })

        XCTAssertFalse(ElevenLabsProvider.entityDetectionOptions.isEmpty)
    }

    func testBuildMultipartBodySetsZDRAndOptions() {
        let provider = ElevenLabsProvider(
            tagAudioEvents: true,
            noVerbatim: true,
            diarize: true,
            numSpeakers: 4,
            detectSpeakerRoles: true,
            useSpeakerLibrary: false,
            timestampsGranularity: "word",
            entityDetection: "pii",
            keyterms: "acme, confidential",
            transcriptEdit: "Capitalize brand names",
            zeroDataRetention: true
        )

        let boundary = "Boundary-123456"
        let dummyWav = Data([0x52, 0x49, 0x46, 0x46])
        let request = provider.buildTranscriptionRequest(
            apiKey: "test-key-123",
            wav: dummyWav,
            model: "scribe_v2",
            language: "en",
            boundary: boundary
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key-123")
        let bodyString = String(decoding: request.httpBody ?? Data(), as: UTF8.self)

        XCTAssertTrue(bodyString.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
        XCTAssertTrue(bodyString.contains("name=\"language_code\"\r\n\r\nen"))
        XCTAssertTrue(bodyString.contains("name=\"tag_audio_events\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"no_verbatim\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"diarize\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"num_speakers\"\r\n\r\n4"))
        XCTAssertTrue(bodyString.contains("name=\"detect_speaker_roles\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"entity_detection\"\r\n\r\npii"))
        XCTAssertTrue(bodyString.contains("name=\"keyterms\"\r\n\r\nacme"))
        XCTAssertTrue(bodyString.contains("name=\"keyterms\"\r\n\r\nconfidential"))
        XCTAssertTrue(bodyString.contains("name=\"transcript_edit\"\r\n\r\nCapitalize brand names"))
        XCTAssertTrue(bodyString.contains("name=\"enable_logging\"\r\n\r\nfalse"), "ZDR must pass enable_logging=false")
    }

    func testParseElevenLabsSuccessResponse() throws {
        let json = """
        {
            "text": "This is a transcribed sentence from ElevenLabs Scribe.",
            "language_code": "en",
            "language_probability": 0.99
        }
        """.data(using: .utf8)!

        struct Response: Decodable {
            let text: String
        }

        let decoded = try JSONDecoder().decode(Response.self, from: json)
        XCTAssertEqual(decoded.text, "This is a transcribed sentence from ElevenLabs Scribe.")
    }

    func testMissingApiKeyThrowsAppropriateError() async {
        let provider = ElevenLabsProvider(apiKey: nil)
        let dummyWav = Data([0x52, 0x49, 0x46, 0x46])
        do {
            _ = try await provider.transcribe(wav: dummyWav, model: "scribe_v2", language: "en")
            XCTFail("Expected missing key error")
        } catch let error as ProviderError {
            switch error {
            case .missingCredential(let msg):
                XCTAssertFalse(msg.isEmpty)
            default:
                XCTFail("Unexpected ProviderError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
