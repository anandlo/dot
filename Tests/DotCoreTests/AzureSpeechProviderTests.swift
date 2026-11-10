import XCTest

@testable import DotCore

final class AzureSpeechProviderTests: XCTestCase {
    func testAzureProviderPropertiesAndDefaults() {
        let provider = AzureSpeechProvider()
        XCTAssertEqual(provider.id, "azure")
        XCTAssertEqual(provider.displayName, "Azure Speech")
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 60)
        XCTAssertEqual(provider.region, "eastus")
        XCTAssertEqual(provider.recognitionMode, "conversation")
        XCTAssertEqual(provider.profanityFilter, "masked")
        XCTAssertEqual(provider.outputFormat, "detailed")
        XCTAssertTrue(provider.zeroDataRetention)
    }

    func testEndpointURLConstruction() {
        let provider = AzureSpeechProvider(
            region: "westeurope",
            recognitionMode: "dictation",
            profanityFilter: "removed",
            outputFormat: "simple",
            zeroDataRetention: true
        )
        let url = provider.endpointURL(language: "en")
        let urlString = url.absoluteString

        XCTAssertTrue(urlString.contains("westeurope.stt.speech.microsoft.com"))
        XCTAssertTrue(urlString.contains("/speech/recognition/dictation/cognitiveservices/v1"))
        XCTAssertTrue(urlString.contains("language=en-US"))
        XCTAssertTrue(urlString.contains("format=simple"))
        XCTAssertTrue(urlString.contains("profanity=removed"))
    }

    func testLanguageNormalization() {
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage(nil), "en-US")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage(""), "en-US")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("auto"), "en-US")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("en"), "en-US")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("zh"), "zh-CN")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("es"), "es-ES")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("fr"), "fr-FR")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("de"), "de-DE")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("ja"), "ja-JP")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("en-GB"), "en-GB")
        XCTAssertEqual(AzureSpeechProvider.normalizedLanguage("zh_TW"), "zh-TW")
    }

    func testBuildRequestSetsHeadersAndAudioBody() {
        let provider = AzureSpeechProvider(
            region: "eastus",
            recognitionMode: "conversation",
            profanityFilter: "masked",
            outputFormat: "detailed",
            zeroDataRetention: true
        )
        let dummyWav = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00])
        let request = provider.buildRequest(apiKey: "azure-secret-key", wav: dummyWav, language: "en_US")

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "azure-secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav; codecs=audio/pcm; samplerate=16000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.httpBody, dummyWav)
    }

    func testDetailedResponseTranscriptParsing() throws {
        let json = """
        {
          "RecognitionStatus": "Success",
          "Offset": 200000,
          "Duration": 25000000,
          "NBest": [
            {
              "Confidence": 0.985,
              "Lexical": "hello world from azure speech",
              "ITN": "hello world from Azure speech",
              "MaskedITN": "hello world from Azure speech",
              "Display": "Hello world from Azure speech."
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try AzureSpeechProvider.transcript(in: json)
        XCTAssertEqual(result, "Hello world from Azure speech.")
    }

    func testSimpleResponseTranscriptParsing() throws {
        let json = """
        {
          "RecognitionStatus": "Success",
          "DisplayText": "Simple transcript output.",
          "Offset": 100000,
          "Duration": 15000000
        }
        """.data(using: .utf8)!

        let result = try AzureSpeechProvider.transcript(in: json)
        XCTAssertEqual(result, "Simple transcript output.")
    }

    func testNoSpeechStatusesThrowNoSpeech() {
        for status in ["NoMatch", "InitialSilenceTimeout", "BabbleTimeout"] {
            let json = """
            {
              "RecognitionStatus": "\(status)",
              "Offset": 0,
              "Duration": 0
            }
            """.data(using: .utf8)!

            XCTAssertThrowsError(try AzureSpeechProvider.transcript(in: json)) { error in
                XCTAssertEqual(error as? ProviderError, ProviderError.noSpeech)
            }
        }
    }

    func testErrorStatusThrowsRejected() {
        let json = """
        {
          "RecognitionStatus": "Error",
          "DisplayText": "Audio format unsupported."
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try AzureSpeechProvider.transcript(in: json)) { error in
            guard case .rejected(let status, let message) = (error as? ProviderError) else {
                XCTFail("Expected .rejected error")
                return
            }
            XCTAssertEqual(status, 200)
            XCTAssertEqual(message, "Audio format unsupported.")
        }
    }

    func testErrorMessageExtraction() {
        let json1 = """
        {"error": {"message": "Invalid subscription key."}}
        """.data(using: .utf8)!
        XCTAssertEqual(AzureSpeechProvider.errorMessage(in: json1), "Invalid subscription key.")

        let json2 = """
        {"message": "Rate limit exceeded."}
        """.data(using: .utf8)!
        XCTAssertEqual(AzureSpeechProvider.errorMessage(in: json2), "Rate limit exceeded.")

        let plainText = "401 Access Denied".data(using: .utf8)!
        XCTAssertEqual(AzureSpeechProvider.errorMessage(in: plainText), "401 Access Denied")
    }

    func testAvailabilityRequiresKey() async {
        let withoutKey = AzureSpeechProvider(apiKey: nil)
        let isAvailNoKey = await withoutKey.isAvailable()
        XCTAssertFalse(isAvailNoKey)

        let withEmptyKey = AzureSpeechProvider(apiKey: "")
        let isAvailEmpty = await withEmptyKey.isAvailable()
        XCTAssertFalse(isAvailEmpty)

        let withKey = AzureSpeechProvider(apiKey: "valid-key")
        let isAvailValid = await withKey.isAvailable()
        XCTAssertTrue(isAvailValid)
    }

    func testStoreAudioQueryParameter() {
        let defaultProvider = AzureSpeechProvider(zeroDataRetention: true)
        let defaultURL = defaultProvider.endpointURL(language: "en")
        XCTAssertTrue(defaultURL.absoluteString.contains("storeAudio=false"), "ZDR default sends storeAudio=false")

        let storedProvider = AzureSpeechProvider(storeAudio: true)
        let storedURL = storedProvider.endpointURL(language: "en")
        XCTAssertTrue(storedURL.absoluteString.contains("storeAudio=true"))

        let notStoredProvider = AzureSpeechProvider(storeAudio: false)
        let notStoredURL = notStoredProvider.endpointURL(language: "en")
        XCTAssertTrue(notStoredURL.absoluteString.contains("storeAudio=false"))
    }

    func testRegistryBuildsAzureWithAllConfigurableSettings() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.azure
        config.providers[ProviderIdentifier.azure] = ProviderConfig(
            azureRegion: "westus2",
            azureRecognitionMode: "dictation",
            azureProfanityFilter: "raw",
            azureOutputFormat: "simple",
            azureStoreAudio: false,
            zeroDataRetention: true
        )

        let provider = try ProviderRegistry.makeProvider(id: ProviderIdentifier.azure, config: config, credentials: .empty)
        guard let azure = provider as? AzureSpeechProvider else {
            XCTFail("Expected AzureSpeechProvider")
            return
        }

        XCTAssertEqual(azure.region, "westus2")
        XCTAssertEqual(azure.recognitionMode, "dictation")
        XCTAssertEqual(azure.profanityFilter, "raw")
        XCTAssertEqual(azure.outputFormat, "simple")
        XCTAssertEqual(azure.storeAudio, false)
        XCTAssertTrue(azure.zeroDataRetention)

        let url = azure.endpointURL(language: "en-US").absoluteString
        XCTAssertTrue(url.contains("westus2.stt.speech.microsoft.com"))
        XCTAssertTrue(url.contains("/speech/recognition/dictation/cognitiveservices/v1"))
        XCTAssertTrue(url.contains("profanity=raw"))
        XCTAssertTrue(url.contains("format=simple"))
        XCTAssertTrue(url.contains("storeAudio=false"))
    }
}
