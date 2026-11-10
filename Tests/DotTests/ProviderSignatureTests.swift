import XCTest
@testable import Dot
@testable import DotCore

/// A provider must only be rebuilt when something it is built from changed.
///
/// Rebuilding is not free: it re-selects the provider and then probes every
/// configured provider, which used to make a click on Appearance or HUD material
/// look like it took ten seconds to take effect.
final class ProviderSignatureTests: XCTestCase {
    func testAppearanceAndDwellDoNotRebuildTheProvider() {
        var config = DotConfig()
        let signature = AppDelegate.ProviderSignature(
            provider: config.provider,
            providers: config.providers
        )

        config.hudMaterial = .glass
        config.hudDwellSeconds = 17
        config.microphoneDeviceUID = "some-device"
        config.autoPaste.toggle()

        let after = AppDelegate.ProviderSignature(
            provider: config.provider,
            providers: config.providers
        )
        XCTAssertEqual(
            signature,
            after,
            "a colour, a dwell, a microphone or auto-paste must not rebuild the provider"
        )
    }

    func testChangingTheSelectedProviderRebuilds() {
        var config = DotConfig()
        let signature = AppDelegate.ProviderSignature(
            provider: config.provider,
            providers: config.providers
        )
        // The default configuration already selects openai, so a real switch has
        // to move to a different id.
        config.provider = "apple"
        let after = AppDelegate.ProviderSignature(
            provider: config.provider,
            providers: config.providers
        )
        XCTAssertNotEqual(signature, after)
    }

    func testChangingAnEndpointModelOrAuthStyleRebuilds() {
        for mutate in [
            { (config: inout DotConfig) in config.providers["openai"]?.baseURL = "https://example.test/v1" },
            { (config: inout DotConfig) in config.providers["openai"]?.model = "whisper-large-v3" },
            { (config: inout DotConfig) in config.providers["openai"]?.authStyle = .apiKey },
        ] {
            var config = DotConfig()
            let signature = AppDelegate.ProviderSignature(
                provider: config.provider,
                providers: config.providers
            )
            mutate(&config)
            let after = AppDelegate.ProviderSignature(
                provider: config.provider,
                providers: config.providers
            )
            XCTAssertNotEqual(signature, after, "an endpoint, a model or an auth style must rebuild")
        }
    }
}
