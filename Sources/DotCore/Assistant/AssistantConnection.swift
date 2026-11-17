import Foundation

/// What the Assistant page says about the service it was told to use.
///
/// The four states are the whole truth the page can state without asking the
/// service: whether the person set an assistant up at all, whether a check is
/// running, whether the service answered, and what happened when it did not.
/// "Connected" is only reached from a successful request: a key in the Keychain
/// is evidence that the speech provider was set up, not that a chat service
/// answers.
public enum AssistantConnectionState: Equatable, Sendable {
    /// Nothing has been chosen, or the chosen service cannot be used.
    case notSetUp
    /// A check is on its way to the service.
    case checking
    /// The service answered its models request.
    case connected
    /// The service refused the request or could not be reached. The string is
    /// the sanitised reason, and it may be empty.
    case notConnected(String)

    /// The words on the status row.
    public var title: String {
        switch self {
        case .notSetUp: "Not set up"
        case .checking: "Checking..."
        case .connected: "Connected"
        case .notConnected: "Couldn't connect"
        }
    }

    /// The line under the status row: the reason, when a check failed.
    public var detail: String? {
        switch self {
        case .notConnected(let reason):
            reason.isEmpty ? nil : reason
        case .notSetUp, .checking, .connected:
            nil
        }
    }
}

/// A change the page reports to its status row.
///
/// The three check events are the page's account of one request, and the
/// availability event is the configuration's: a service that stopped being
/// usable can never be reported as connected, whatever a check that was already
/// in flight answers.
public enum AssistantConnectionEvent: Equatable, Sendable {
    /// The chosen service can, or can no longer, be used at all.
    case availability(isUsable: Bool)
    /// A models request was sent.
    case checkStarted
    /// The models request was answered.
    case checkSucceeded
    /// The models request failed, for `reason`.
    case checkFailed(String)

    /// The state that follows this event.
    ///
    /// ``AssistantConnectionState/notSetUp`` absorbs every check event, so a
    /// late answer from a service the person has since turned off cannot put a
    /// green dot on a page that is not set up.
    ///
    /// - Parameter state: the state the row shows now.
    /// - Returns: the state it shows next.
    public func applied(to state: AssistantConnectionState) -> AssistantConnectionState {
        switch self {
        case .availability(let isUsable):
            guard isUsable else { return .notSetUp }
            // A service that just became usable is checked at that moment, so
            // the row says so rather than claiming a result it does not have.
            return state == .notSetUp ? .checking : state
        case .checkStarted:
            return state == .notSetUp ? state : .checking
        case .checkSucceeded:
            return state == .notSetUp ? state : .connected
        case .checkFailed(let reason):
            return state == .notSetUp ? state : .notConnected(reason)
        }
    }
}

/// The one rule that says whether the assistant can be used.
///
/// The status row, the rewrite chips, the assistant shortcut and the menu item
/// all ask this question, and they have to agree: a person who never set an
/// assistant up is not offered a rewrite, is not allowed a turn and is not told
/// that a service is connected, whatever key happens to be in the Keychain.
public enum AssistantAvailability {
    /// Why the assistant can, or cannot, be used.
    ///
    /// The cases are in the order a person fixes them: rewriting has to be
    /// turned on, the service has to have what it needs, and the address it is
    /// reached at has to be one a request can be built from. A record that says
    /// it is set up but names no address is not usable, however good the key.
    public enum Readiness: Equatable, Sendable {
        /// A turn could be asked of the chosen service.
        case ready
        /// The person has not turned the assistant on.
        case notSetUp
        /// The service cannot be used without a key, and none is stored.
        case missingKey(service: String)
        /// The record names no address and the catalogue row ships none.
        case missingAddress
        /// The address was refused by ``EndpointPolicy``.
        case refusedAddress(EndpointPolicy.Rejection)

        /// Whether a turn could be asked.
        public var isReady: Bool { self == .ready }

        /// The line that says what to do next, or `nil` when nothing is left.
        ///
        /// It is one sentence because it sits under the status row, and it
        /// never repeats the typed address: an address can carry a query string
        /// or a credential, and the status row is not the place to print it.
        public var message: String? {
            switch self {
            case .ready:
                nil
            case .notSetUp:
                "Choose a service to turn AI rewrite on."
            case .missingKey(let service):
                "Add a key for \(service)."
            case .missingAddress:
                "Add the address this service is reached at."
            case .refusedAddress(let rejection):
                rejection.safeDescription
            }
        }
    }

    /// Whether a turn could be asked of the chosen service, and why not.
    ///
    /// The question is asked of the sanitized record, because that is what
    /// ``AssistantProviderCatalogue/makeProvider(settings:apiKey:session:temperature:forRewrite:)``
    /// builds from: an assistant is usable exactly when the provider a turn
    /// needs can be built without a request being sent. Nothing here touches the
    /// network, so the menu, the chips and the page answer at once.
    ///
    /// - Parameters:
    ///   - config: the assistant's block of the configuration.
    ///   - hasKey: whether the Keychain holds a key for the chosen service. A
    ///     service that runs on this Mac asks for none, so it passes without.
    /// - Returns: the first thing that has to change, or ``Readiness/ready``.
    public static func readiness(config: AssistantConfiguration, hasKey: Bool) -> Readiness {
        guard config.isSetUp else { return .notSetUp }
        let settings = config.chat.sanitized()
        let row = AssistantProviderCatalogue.row(for: settings.resolvedProviderID)
        // The order mirrors the provider factory: a missing key is named before
        // the address, because a service that needs one cannot be used at all.
        guard !row.requiresKey || hasKey else { return .missingKey(service: row.name) }
        let baseURL: URL?
        do {
            baseURL = try AssistantProviderCatalogue.resolvedBaseURL(settings: settings, row: row)
        } catch let rejection as EndpointPolicy.Rejection {
            return .refusedAddress(rejection)
        } catch {
            // The resolver throws only a rejection; an address it cannot parse
            // is still an address no request can be built from.
            return .refusedAddress(.notAnAddress(settings.baseURL ?? ""))
        }
        guard let baseURL else { return .missingAddress }
        // The row's own address is held to the same rule the typed one is: a
        // default is a shipped value, not a promise that it is reachable.
        if let rejection = EndpointPolicy.validate(baseURL) {
            return .refusedAddress(rejection)
        }
        return .ready
    }

    /// Whether a turn could be asked of the chosen service.
    ///
    /// - Parameters:
    ///   - config: the assistant's block of the configuration.
    ///   - hasKey: whether the Keychain holds a key for the chosen service.
    /// - Returns: whether the person set the assistant up and the service can
    ///   be built from what is stored.
    public static func isUsable(config: AssistantConfiguration, hasKey: Bool) -> Bool {
        readiness(config: config, hasKey: hasKey).isReady
    }
}

/// What a models request said about a service.
public enum AssistantConnectionResult: Equatable, Sendable {
    /// The service answered with a success.
    case connected
    /// The service refused the request or could not be reached. The string is
    /// the sanitised reason.
    case notConnected(String)

    /// The state the status row shows for this result.
    public var state: AssistantConnectionState {
        switch self {
        case .connected: .connected
        case .notConnected(let reason): .notConnected(reason)
        }
    }
}

/// Asks a service whether it answers, with the models request it documents.
///
/// The request is the cheapest one that proves the address, the key and the
/// account all work: `GET <base>/models`, the same call the model picker reads.
/// It is sent through ``HTTPTransport`` so an oversized answer cannot become
/// Dot's memory, and the address is checked by ``EndpointPolicy`` in the request
/// builder, so a proxy is held to the same rule a speech endpoint is.
public enum AssistantConnectionVerifier {
    /// How long a check may take before it counts as unreachable.
    public static let timeout: TimeInterval = 8

    /// The session a check is sent with, built once.
    ///
    /// A check is a single small request with a short deadline; the page does
    /// not own a session, so one is shared rather than leaking one per check.
    public static let sharedSession = makeSession()

    /// Sends the models request and reads its status.
    ///
    /// - Parameters:
    ///   - settings: the chat settings, which name the service and any typed
    ///     address.
    ///   - apiKey: the key, when the service needs one.
    ///   - session: the session to send with.
    /// - Returns: what the status row shows.
    public static func verify(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession
    ) async -> AssistantConnectionResult {
        let request: URLRequest
        do {
            request = try AssistantModelCatalog.makeRequest(settings: settings, apiKey: apiKey)
        } catch {
            return .notConnected(detail(for: error))
        }
        do {
            let answer = try await HTTPTransport.send(request, session: session)
            guard let response = answer.response as? HTTPURLResponse else {
                return .notConnected("The answer was not an HTTP response")
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                return .notConnected(detail(forStatus: response.statusCode))
            }
            return .connected
        } catch {
            return .notConnected(detail(for: error))
        }
    }

    /// The sentence a status code produces.
    ///
    /// The two refusals a person can act on are named; everything else is the
    /// status itself, because a guess at what a service meant is worse than the
    /// number it sent.
    ///
    /// - Parameter status: the code the service answered with.
    /// - Returns: the line the status row shows.
    public static func detail(forStatus status: Int) -> String {
        switch status {
        case 401, 403:
            "Rejected the key (\(status))"
        case 404:
            "The service has no models endpoint (404)"
        default:
            "The service answered \(status)"
        }
    }

    /// The sentence a thrown error produces, with a provider's words made safe
    /// to show.
    ///
    /// - Parameter error: what the request threw.
    /// - Returns: the line the status row shows.
    static func detail(for error: Error) -> String {
        if let rejection = error as? EndpointPolicy.Rejection {
            // The rejected address is not repeated: it can carry a query string,
            // and the status row is the one place it would be shown back.
            return ProviderErrorText.sanitized(rejection.safeDescription)
                ?? "That address cannot be used."
        }
        if let failure = error as? ProviderError {
            return ProviderErrorText.sanitized(failure.errorDescription)
                ?? "The service could not be reached."
        }
        return ProviderErrorText.sanitized(error.localizedDescription)
            ?? "The service could not be reached."
    }

    /// The session a check is sent with.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }
}

/// The checks this run of the app has already made.
///
/// Opening the page twice in a minute must not send the service two requests,
/// and the first request is made by the page rather than at launch, which is
/// what keeps the app's memory flat until someone looks. The results live in
/// memory only: nothing about a service is written to the configuration, and a
/// new launch checks again.
public actor AssistantConnectionCache {
    /// How long a result is reused.
    public static let lifetime: TimeInterval = 600

    /// The cache the page uses.
    public static let shared = AssistantConnectionCache()

    private var results: [String: (result: AssistantConnectionResult, at: Date)] = [:]

    public init() {}

    /// The name a result is stored under: the service and the address it was
    /// asked at, so a service the person moved is checked at its new address.
    ///
    /// - Parameter settings: the chat settings.
    /// - Returns: the key a result and a check share.
    public static func serviceKey(_ settings: AssistantSettings) -> String {
        let address = settings.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return settings.sanitized().providerID + " " + address
    }

    /// The result that is still fresh, when there is one.
    ///
    /// - Parameters:
    ///   - service: the key ``serviceKey(_:)`` built.
    ///   - now: the moment the caller asks.
    /// - Returns: the result, or `nil` when none was stored or it is older than
    ///   ``lifetime``.
    public func result(for service: String, now: Date) -> AssistantConnectionResult? {
        guard let stored = results[service] else { return nil }
        guard now.timeIntervalSince(stored.at) < Self.lifetime else {
            results[service] = nil
            return nil
        }
        return stored.result
    }

    /// Records what a check found.
    public func store(_ result: AssistantConnectionResult, for service: String, at date: Date) {
        results[service] = (result, date)
    }

}
