import XCTest
@testable import DotCore

final class DeepgramProviderTests: XCTestCase {
    func testDeepgramProviderPropertiesAndDefaults() {
        let provider = DeepgramProvider()
        XCTAssertEqual(provider.id, "deepgram")
        XCTAssertEqual(provider.displayName, "Deepgram")
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 30)
        XCTAssertEqual(DeepgramProvider.defaultModel, "nova-3")
        XCTAssertEqual(DeepgramProvider.defaultBaseURL, URL(string: "https://api.deepgram.com/v1")!)
        XCTAssertTrue(provider.smartFormat)
        XCTAssertTrue(provider.punctuate)
        XCTAssertFalse(provider.paragraphs)
        XCTAssertFalse(provider.fillerWords)
        XCTAssertFalse(provider.profanityFilter)
        XCTAssertFalse(provider.numerals)
        XCTAssertFalse(provider.diarize)
        XCTAssertNil(provider.keyterms)
        XCTAssertTrue(provider.zeroDataRetention)
    }

    func testListenURLConstructionWithDefaults() {
        let provider = DeepgramProvider(zeroDataRetention: true)
        let url = provider.listenURL(model: nil, language: "en")
        let urlString = url.absoluteString

        XCTAssertTrue(urlString.hasPrefix("https://api.deepgram.com/v1/listen"))
        XCTAssertTrue(urlString.contains("model=nova-3"))
        XCTAssertTrue(urlString.contains("language=en"))
        XCTAssertTrue(urlString.contains("smart_format=true"))
        XCTAssertTrue(urlString.contains("punctuate=true"))
        XCTAssertTrue(urlString.contains("mip_opt_out=true"), "ZDR must pass mip_opt_out=true")
    }

    func testListenURLConstructionWithOptions() {
        let provider = DeepgramProvider(
            smartFormat: true,
            punctuate: true,
            paragraphs: true,
            fillerWords: true,
            profanityFilter: true,
            numerals: true,
            diarize: true,
            keyterms: "medical, oncology, dosage",
            zeroDataRetention: false
        )
        let url = provider.listenURL(model: "nova-3-medical", language: "zh")
        let urlString = url.absoluteString

        XCTAssertTrue(urlString.contains("model=nova-3-medical"))
        XCTAssertTrue(urlString.contains("language=zh"))
        XCTAssertTrue(urlString.contains("paragraphs=true"))
        XCTAssertTrue(urlString.contains("filler_words=true"))
        XCTAssertTrue(urlString.contains("profanity_filter=true"))
        XCTAssertTrue(urlString.contains("numerals=true"))
        XCTAssertTrue(urlString.contains("diarize=true"))
        XCTAssertTrue(urlString.contains("keyterm=medical"))
        XCTAssertTrue(urlString.contains("keyterm=oncology"))
        XCTAssertTrue(urlString.contains("keyterm=dosage"))
        XCTAssertFalse(urlString.contains("mip_opt_out=true"), "When ZDR is disabled, mip_opt_out should not be sent")
    }

    func testParseDeepgramSuccessResponse() throws {
        let json = """
        {
            "metadata": { "request_id": "test-req-123" },
            "results": {
                "channels": [
                    {
                        "alternatives": [
                            {
                                "transcript": "Hello world from Deepgram Nova.",
                                "confidence": 0.985
                            }
                        ]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        struct Response: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String
                        let confidence: Double?
                    }
                    let alternatives: [Alternative]
                }
                let channels: [Channel]
            }
            let results: Results
        }

        let decoded = try JSONDecoder().decode(Response.self, from: json)
        let transcript = decoded.results.channels.first?.alternatives.first?.transcript
        XCTAssertEqual(transcript, "Hello world from Deepgram Nova.")
    }

    func testMissingApiKeyThrowsAppropriateError() async {
        let provider = DeepgramProvider(apiKey: nil)
        let dummyWav = Data([0x52, 0x49, 0x46, 0x46])
        do {
            _ = try await provider.transcribe(wav: dummyWav, model: "nova-3", language: "en")
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
