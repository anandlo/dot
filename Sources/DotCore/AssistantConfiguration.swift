import Foundation

/// Everything the AI rewrite engine reads.
///
/// It is one top-level block of the configuration file, not a field of any
/// provider: ``ProviderMigration`` deletes keys it does not know from the
/// `providers` table, and a rewrite setting living there would be erased on
/// the next launch.
///
/// Decoding is tolerant field by field: a bad value resets only the field it is
/// in, and retired spoken-assistant keys (`voice`, `connectors`, `delivery`,
/// `actionsEnabled`) from older configuration files are ignored cleanly.
public struct AssistantConfiguration: Codable, Sendable, Equatable {
    /// The service, model and sampling rewrites are asked of.
    public var chat: AssistantSettings
    /// Which rewrites the transcript card offers after a dictation.
    public var rewrite: RewriteConfiguration
    /// Whether the person set the service up on purpose.
    ///
    /// A chat key is the Keychain item the speech provider writes, so a stored
    /// key says nothing about whether a service was chosen: an install with
    /// an OpenAI speech key would otherwise be reported as connected by a person
    /// who never picked one. Only the AI rewrite page sets this, and only after
    /// the person picked a service and gave it a key (or picked one that runs on
    /// this Mac) or accepted the key the Speech to text page already stored, or
    /// pressed the switch that turns a keyless endpoint on.
    public var isSetUp: Bool
    /// Whether a service is chosen, whether or not rewriting is on.
    ///
    /// It is what separates an unfinished choice from "None": turning rewriting
    /// off must not destroy the service, its model or a typed address, so the
    /// record keeps them and this says whether the page should present them.
    /// `nil` in a file written before this key existed; such a file is read by
    /// its stored service.
    public var serviceChosen: Bool?

    /// The configuration a fresh install starts with.
    public static let `default` = AssistantConfiguration()

    /// Creates a configuration.
    public init(
        chat: AssistantSettings = .default,
        rewrite: RewriteConfiguration = .default,
        isSetUp: Bool = false,
        serviceChosen: Bool? = nil
    ) {
        self.chat = chat
        self.rewrite = rewrite
        self.isSetUp = isSetUp
        self.serviceChosen = serviceChosen
    }

    /// The model id a request is asked for, resolved from the catalogue.
    public var model: String {
        AssistantProviderCatalogue.model(for: chat)
    }

    private enum CodingKeys: String, CodingKey {
        case chat
        case rewrite
        case isSetUp
        case serviceChosen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AssistantConfiguration.default
        chat = ((try? container.decodeIfPresent(AssistantSettings.self, forKey: .chat)) ?? nil) ?? fallback.chat
        rewrite = ((try? container.decodeIfPresent(RewriteConfiguration.self, forKey: .rewrite)) ?? nil)
            ?? fallback.rewrite
        isSetUp = ((try? container.decodeIfPresent(Bool.self, forKey: .isSetUp)) ?? nil)
            ?? fallback.isSetUp
        serviceChosen = (try? container.decodeIfPresent(Bool.self, forKey: .serviceChosen)) ?? nil
    }
}
