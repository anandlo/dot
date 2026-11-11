import XCTest

@testable import DotCore

/// The voice matrix is product surface: a row that is not wired must say so, and
/// an endpoint with a shutdown date must carry that date where Settings can show
/// it. These tests hold both promises, and the date itself, so a build cannot
/// quietly keep recommending OpenAI after 6 January 2027.
final class VoicePresetTests: XCTestCase {
    func testEveryProviderIDHasOneRow() {
        XCTAssertEqual(VoicePresets.all.count, VoiceProviderID.all.count)
        XCTAssertEqual(Set(VoicePresets.all.map(\.id)), Set(VoiceProviderID.all))
        XCTAssertEqual(VoicePresets.all.map(\.rank), [1, 2, 3, 4, 5, 6])
    }

    func testTheRecommendedOrderIsTheLadder() {
        XCTAssertEqual(
            VoicePresets.all.map(\.id),
            ["apple", "cartesia", "elevenlabs", "azure", "deepgram", "openai"]
        )
    }

    func testOnlyTheOnDeviceRowNeedsNoKey() {
        XCTAssertFalse(VoicePresets.apple.requiresCredential)
        for preset in VoicePresets.keyed {
            XCTAssertTrue(preset.requiresCredential, "\(preset.id) should need a key")
        }
        XCTAssertEqual(VoicePresets.keyed.count, VoicePresets.all.count - 1)
    }

    func testTheOnDeviceRowIsVerifiedAndTheUnconfirmedRowsSayWhy() {
        XCTAssertEqual(VoicePresets.apple.verification, .verified)
        for preset in VoicePresets.all where preset.id != VoiceProviderID.apple {
            XCTAssertFalse(preset.verification.isVerified, "\(preset.id) is not fully verified")
            XCTAssertNotNil(preset.verification.note)
            XCTAssertFalse((preset.verification.note ?? "").isEmpty)
        }
    }

    func testOpenAIshutdownDateIsTheSixthOfJanuary2027() {
        let deprecation = try? XCTUnwrap(VoicePresets.openAI.deprecation)
        XCTAssertEqual(deprecation?.isoDate, "2027-01-06")
        XCTAssertEqual(deprecation?.year, 2027)
        XCTAssertEqual(deprecation?.month, 1)
        XCTAssertEqual(deprecation?.day, 6)
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(
            deprecation?.shutdownDate,
            formatter.date(from: "2027-01-06T00:00:00Z")
        )
    }

    func testTheCountdownAndTheShutdownReadCorrectly() throws {
        let deprecation = try XCTUnwrap(VoicePresets.openAI.deprecation)
        let formatter = ISO8601DateFormatter()
        let newYear = try XCTUnwrap(formatter.date(from: "2027-01-01T00:00:00Z"))
        XCTAssertEqual(deprecation.daysRemaining(asOf: newYear), 5)
        XCTAssertFalse(deprecation.isShutDown(asOf: newYear))
        let shutdown = try XCTUnwrap(formatter.date(from: "2027-01-06T00:00:00Z"))
        XCTAssertTrue(deprecation.isShutDown(asOf: shutdown))
        XCTAssertEqual(deprecation.daysRemaining(asOf: shutdown), 0)
        XCTAssertTrue(VoicePresets.shutDown(asOf: shutdown).map(\.id) == ["openai"])
        XCTAssertTrue(VoicePresets.shutDown(asOf: newYear).isEmpty)
    }

    func testEveryOpenAIModelIsMarkedDeprecated() {
        let models = VoicePresets.openAI.models
        XCTAssertFalse(models.isEmpty)
        for model in models {
            XCTAssertTrue(model.isDeprecated, "\(model.id) must carry the shutdown warning")
        }
        XCTAssertEqual(VoicePresets.openAI.defaultModel, "gpt-4o-mini-tts")
        XCTAssertEqual(OpenAIVoiceProvider.deprecation, VoicePresets.openAI.deprecation)
    }

    func testTheWarningShowsDaysBeforeAndTheMessageAfter() throws {
        let formatter = ISO8601DateFormatter()
        let newYear = try XCTUnwrap(formatter.date(from: "2027-01-01T00:00:00Z"))
        let warning = try XCTUnwrap(VoicePresets.openAI.deprecationWarning(asOf: newYear))
        XCTAssertTrue(warning.contains("5 days left"))
        let shutdown = try XCTUnwrap(formatter.date(from: "2027-02-01T00:00:00Z"))
        XCTAssertEqual(
            VoicePresets.openAI.deprecationWarning(asOf: shutdown),
            VoicePresets.openAI.deprecation?.message
        )
        XCTAssertNil(VoicePresets.apple.deprecationWarning(asOf: newYear))
    }

    func testTheFactoryBuildsEveryKnownRowAndNothingElse() {
        XCTAssertNil(VoiceProviderFactory.make(providerID: "nope", apiKey: "k"))
        XCTAssertTrue(
            VoiceProviderFactory.make(providerID: " Apple ", apiKey: nil) is AppleVoiceProvider
        )
        XCTAssertTrue(
            VoiceProviderFactory.make(providerID: "cartesia", apiKey: "k") is CartesiaVoiceProvider
        )
        XCTAssertTrue(
            VoiceProviderFactory.make(providerID: "elevenlabs", apiKey: "k") is ElevenLabsVoiceProvider
        )
        XCTAssertTrue(VoiceProviderFactory.make(providerID: "azure", apiKey: "k") is AzureVoiceProvider)
        XCTAssertTrue(VoiceProviderFactory.make(providerID: "deepgram", apiKey: "k") is DeepgramVoiceProvider)
        XCTAssertTrue(VoiceProviderFactory.make(providerID: "openai", apiKey: "k") is OpenAIVoiceProvider)
        XCTAssertEqual(VoiceProviderFactory.normalized(" OpenAI\n"), "openai")
    }

    func testTheFactoryUsesTheCachedKeyForTheSameVendorID() {
        let cache = CredentialCache(reader: { id in id == "cartesia" ? .key("cached-key") : .missing })
        let provider = VoiceProviderFactory.make(providerID: "cartesia", credentials: cache)
        XCTAssertEqual((provider as? CartesiaVoiceProvider)?.apiKey, "cached-key")
        XCTAssertEqual(cache.readCount, 1)
    }
}

// MARK: - The bounded factory

extension VoicePresetTests {
    func testTheAsyncFactoryResolvesTheKeyWithoutBlockingTheCaller() async {
        let cache = CredentialCache(reader: { _ in .key("async-key") })
        let provider = await VoiceProviderFactory.make(providerID: "deepgram", credentials: cache)
        XCTAssertEqual((provider as? DeepgramVoiceProvider)?.apiKey, "async-key")
        XCTAssertEqual(cache.readCount, 1)
    }

    func testTheAsyncFactoryGivesUpOnASlowKeychain() async {
        let cache = CredentialCache(reader: { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .key("late")
        })
        let provider = await VoiceProviderFactory.make(
            providerID: "deepgram",
            credentials: cache,
            timeout: .milliseconds(50)
        )
        XCTAssertNil((provider as? DeepgramVoiceProvider)?.apiKey)
        XCTAssertNotNil(provider, "a slow Keychain must not remove the row")
    }

    func testTheAsyncFactoryNeverAsksForAnOnDeviceKey() async {
        let cache = CredentialCache(reader: { _ in
            XCTFail("the on-device provider has no key to read")
            return .missing
        })
        let provider = await VoiceProviderFactory.make(providerID: "apple", credentials: cache)
        XCTAssertTrue(provider is AppleVoiceProvider)
        XCTAssertEqual(cache.readCount, 0)
    }
}
