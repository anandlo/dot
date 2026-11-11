import Foundation

/// Moves a configuration off a provider id Dot no longer ships.
///
/// A configuration file written by an older build may name a provider id that
/// no longer exists — the ``ProviderIdentifier/bridge`` tombstone is one, and a
/// typo is another. ``retireDeadProviders(in:probe:)`` is the one place such an
/// id is corrected. It runs at launch, before anything builds a provider, and it
/// asks the Keychain one attributes-only question per built-in provider through
/// ``CredentialProbe``, so no system prompt can leave the app on a tombstone. A
/// provider Dot still knows keeps the id the user chose. Its *settings* are
/// repaired when they name a service without carrying that service's endpoint
/// (``fillMissingEndpoints(in:)``), because that configuration builds nothing.
///
/// The replacement is not written into this file. It is the first provider in
/// ``ProviderRegistry/builtInIDs`` order whose key actually exists, and the
/// zero-key row when none does. A Mac whose only key belongs to one service
/// lands on that service because the key is there, not because the code
/// expected it.
public enum ProviderMigration {
    /// What the launch correction found and did.
    public struct Correction: Equatable, Sendable {
        /// The selected provider id the configuration named that Dot cannot
        /// build. Empty when only settings of a retired provider were removed.
        public let retiredIDs: [String]
        /// The live provider the configuration selects after the correction.
        public let selectedID: String
        /// Whether the replacement was chosen while no key was known to exist,
        /// so the background credential migration may still move it to a
        /// service whose key it is copying later in the same launch.
        public let awaitingKey: Bool
        /// Providers whose settings named a service but carried no endpoint, and
        /// whose preset's endpoint was written in.
        public let filledEndpoints: [String]

        /// Creates a correction.
        public init(
            retiredIDs: [String],
            selectedID: String,
            awaitingKey: Bool,
            filledEndpoints: [String] = []
        ) {
            self.retiredIDs = retiredIDs
            self.selectedID = selectedID
            self.awaitingKey = awaitingKey
            self.filledEndpoints = filledEndpoints
        }
    }

    /// Loads the configuration and retires a provider Dot cannot build, as one
    /// step.
    ///
    /// This is what launch calls instead of ``DotConfig/load(from:)``: a
    /// configuration is only ever handed on after the correction, so no caller
    /// can build a provider from an id that does not exist. ``DotConfig`` is
    /// passed through unchanged, including the tombstone id, when it is already
    /// sound.
    ///
    /// - Parameters:
    ///   - url: the file to read.
    ///   - probe: the Keychain seam.
    /// - Returns: the configuration to use and what was corrected, if anything.
    public static func loadConfiguration(
        from url: URL = DotConfig.defaultURL(),
        probe: CredentialProbe = CredentialProbe()
    ) -> (config: DotConfig, correction: Correction?) {
        var config = DotConfig.load(from: url)
        let filled = fillMissingEndpoints(in: &config)
        let correction = retireDeadProviders(in: &config, probe: probe)
        switch (correction, filled.isEmpty) {
        case (let correction?, _):
            return (config, Correction(
                retiredIDs: correction.retiredIDs,
                selectedID: config.provider,
                awaitingKey: correction.awaitingKey,
                filledEndpoints: filled
            ))
        case (nil, false):
            return (config, Correction(
                retiredIDs: [],
                selectedID: config.provider,
                awaitingKey: false,
                filledEndpoints: filled
            ))
        case (nil, true):
            return (config, nil)
        }
    }

    /// Writes in the endpoint of a service that names one but does not carry it.
    ///
    /// A settings record can lose its base URL — an older build wrote only the
    /// model, a migration moved the id — and the result is worse than a broken
    /// field: ``ProviderRegistry`` refuses to build the provider, so a Mac that
    /// names OpenAI has no provider at all and every press does nothing. The
    /// endpoint written in is the preset's own, so nothing is guessed, and only
    /// a row that declares one is touched: a custom endpoint is the user's own
    /// URL and an empty one there means they have not typed it yet, and the
    /// on-device transcriber has no endpoint at all.
    ///
    /// The row is looked up by *provider* id. A row's own id is not the id the
    /// configuration stores — Apple's row is `on-device` and the custom row
    /// shares `openai` with OpenAI's — so a lookup by row id would silently skip
    /// the providers whose two ids differ.
    ///
    /// - Parameter config: the configuration to repair.
    /// - Returns: the providers whose endpoint was written, sorted.
    @discardableResult
    public static func fillMissingEndpoints(in config: inout DotConfig) -> [String] {
        var filled: [String] = []
        for (id, settings) in config.providers {
            let endpointIsMissing = settings.baseURL?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            guard endpointIsMissing,
                  let preset = ProviderPreset.endpoint(forProviderID: id),
                  let endpoint = preset.baseURL,
                  !endpoint.isEmpty
            else { continue }
            var repaired = settings
            repaired.baseURL = endpoint
            config.providers[id] = repaired
            filled.append(id)
        }
        return filled.sorted()
    }

    /// Retires every provider Dot cannot build, and nothing else.
    ///
    /// This is the launch step and the only corrector of the selected id. It
    /// runs unconditionally, before the first provider is built, and it is
    /// deliberately independent of
    /// ``DotMigration/migrateCredentialsAtLaunch(within:credentials:)``:
    /// retiring a provider has nothing to do with secrets, so it must not wait
    /// for one to be read. When the Keychain prompt behind that copy times out,
    /// the app still comes up on a provider that exists.
    ///
    /// The Keychain questions it asks — "is there a key for this provider?" — are
    /// answered from the item's attributes (``CredentialProbe/hasKey``), one per
    /// built-in provider at most. Reading the data would make macOS decrypt the
    /// item, and decrypting an item whose signature changed waits for a system
    /// prompt: that is exactly how a configuration was once left pointing at a
    /// provider that does not exist. ``CredentialProbe/readKey`` is therefore
    /// never called here.
    ///
    /// The settings of a retired provider are removed with it: nothing can read
    /// them again, and a configuration file must not keep naming an id the app
    /// cannot build.
    ///
    /// - Parameters:
    ///   - config: the configuration to correct.
    ///   - probe: the Keychain seam; injected so a test never touches the real
    ///     Keychain, and separated so a test can fail on a data read.
    /// - Returns: what was corrected, or `nil` when the configuration was
    ///   already sound and nothing has to be written back.
    @discardableResult
    public static func retireDeadProviders(
        in config: inout DotConfig,
        probe: CredentialProbe = CredentialProbe()
    ) -> Correction? {
        let selectionIsDead = !ProviderRegistry.knows(config.provider)
        let deadSettings = config.providers.keys
            .filter { !ProviderRegistry.knows($0) }
            .sorted()
        guard selectionIsDead || !deadSettings.isEmpty else { return nil }

        let retired = selectionIsDead ? config.provider : nil
        var awaitingKey = false
        if selectionIsDead {
            awaitingKey = !selectBestAvailable(in: &config, probe: probe)
        }
        for id in deadSettings {
            config.providers.removeValue(forKey: id)
        }
        return Correction(
            retiredIDs: retired.map { [$0] } ?? [],
            selectedID: config.provider,
            awaitingKey: awaitingKey
        )
    }

    /// The upgrade a late credential copy may still make.
    ///
    /// ``retireDeadProviders(in:probe:)`` has to answer "which keys exist?"
    /// before the background copy of an older build's key has run, so its answer
    /// can go stale within the same launch. A replacement that was chosen for
    /// want of a key becomes the service whose key now exists. A provider the
    /// user chose is never touched: only the id this correction selected is
    /// upgraded, and only while it is still selected.
    ///
    /// A user who picks the same provider this correction picked cannot be told
    /// apart from it, and does not have to be: the id is the same either way, so
    /// the later key is the only thing that changes.
    ///
    /// - Parameters:
    ///   - config: the configuration to upgrade.
    ///   - correction: what the launch corrected, if anything.
    ///   - probe: the Keychain seam, asked attributes-only questions.
    /// - Returns: whether the configuration changed and has to be saved.
    @discardableResult
    public static func upgrade(
        _ config: inout DotConfig,
        after correction: Correction?,
        probe: CredentialProbe = CredentialProbe()
    ) -> Bool {
        guard let correction,
              correction.awaitingKey,
              config.provider == correction.selectedID,
              let id = bestAvailable(probe: probe),
              id != config.provider
        else { return false }
        select(id, in: &config)
        return true
    }

    // MARK: - The choice

    /// Selects the best provider that is usable right now.
    ///
    /// - Parameters:
    ///   - config: the configuration to update.
    ///   - probe: the Keychain seam.
    /// - Returns: whether a key was found. `false` means the zero-key row was
    ///   selected, so the choice may still change when a key arrives.
    private static func selectBestAvailable(
        in config: inout DotConfig,
        probe: CredentialProbe
    ) -> Bool {
        if let id = bestAvailable(probe: probe) {
            select(id, in: &config)
            return true
        }
        select(zeroKeyProviderID, in: &config)
        return false
    }

    /// The provider Dot can use right now, or `nil` when no key exists.
    ///
    /// The order is ``ProviderRegistry/builtInIDs`` order, so the answer is
    /// deterministic and does not depend on the order the configuration happens
    /// to list its settings in.
    private static func bestAvailable(probe: CredentialProbe) -> String? {
        keyedProviderIDs.first { probe.hasKey($0) }
    }

    /// The provider ids that refuse requests without a key, in registry order.
    ///
    /// The declared rows are read rather than the offered ones: a key that
    /// exists still says which service to use, even for a provider the picker
    /// no longer draws, and a configuration that lands on one of those is
    /// presented as the custom endpoint it already is.
    private static var keyedProviderIDs: [String] {
        ProviderRegistry.builtInIDs.filter { id in
            ProviderPreset.declared.contains { $0.providerID == id && $0.needsKey }
        }
    }

    /// The provider that needs no key: the honest replacement when no key
    /// exists at all.
    private static var zeroKeyProviderID: String {
        ProviderPreset.all.first { $0.key == .none }?.providerID
            ?? ProviderIdentifier.openAI
    }

    /// Selects a provider and gives it the endpoint and model it needs.
    ///
    /// A key says which service to use, never which endpoint or model it
    /// belongs to, so nothing here overwrites what the configuration already
    /// holds: only a missing value is filled in, from the defaults that ship
    /// with the build.
    ///
    /// - Parameters:
    ///   - id: the provider to select.
    ///   - config: the configuration to update.
    private static func select(_ id: String, in config: inout DotConfig) {
        config.provider = id
        guard let defaults = DotConfig.defaultProviders[id] else { return }
        var settings = config.settings(for: id)
        if settings.baseURL?.isEmpty != false, let baseURL = defaults.baseURL {
            settings.baseURL = baseURL
        }
        if settings.model?.isEmpty != false, let model = defaults.model {
            settings.model = model
        }
        config.providers[id] = settings
    }
}
