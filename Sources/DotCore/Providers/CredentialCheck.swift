import CryptoKit
import Foundation

/// What a provider's own service said about the credential Dot holds for it.
///
/// The seven cases are the whole truth a page can state after one request: the
/// service accepted the key, accepted it but refused the read for a permission,
/// refused it, answered with a failure of its own, gave an answer that is
/// neither, needs something set up first, or cannot run on this machine at all.
/// The one word a row shows and the sentence its tooltip carries are both here,
/// so the page and the log cannot disagree about what a check found.
public enum CredentialCheck: Sendable, Equatable {
    /// The service answered a success.
    case verified
    /// The service accepted the credential but refused this read because the
    /// key lacks a permission. The sentence says what the service allowed; the
    /// one word is still ``verified`` because a dictation key that cannot list
    /// models can still transcribe.
    case verifiedWithRestriction(String)
    /// The service refused the credential with 401 or 403. The status is kept:
    /// a 403 is a permission the key lacks, not a bad key.
    case rejected(status: Int)
    /// The service answered 429 or 5xx: the credential was not judged.
    case serviceError(status: Int, host: String)
    /// The service was reached but answered something else, or was not reached.
    case unreachable(String)
    /// The credential or the machine's setup is missing.
    case needsSetup(String)
    /// The provider cannot run here.
    case unavailable(String)

    /// The one or two words the settings row shows beside the service name.
    public var title: String {
        switch self {
        case .verified, .verifiedWithRestriction: "Verified"
        case .rejected: "Key rejected"
        case .serviceError: "Service error"
        case .unreachable: "Can't reach service"
        case .needsSetup: "Needs setup"
        case .unavailable: "Unavailable"
        }
    }

    /// The full sentence: the row's tooltip and its accessibility value.
    ///
    /// A case that carries its own words shows them; the two cases a request
    /// produces without a message say what the request found.
    public var message: String {
        switch self {
        case .verified:
            "The service answered with this key."
        case .verifiedWithRestriction(let detail):
            detail
        case .rejected(let status):
            status == 403
                ? "HTTP 403: the key was refused for this request"
                : "The service refused this key."
        case .serviceError(let status, let host):
            "HTTP \(status) from \(host)"
        case .unreachable(let detail):
            detail
        case .needsSetup(let detail):
            detail
        case .unavailable(let detail):
            detail
        }
    }

    /// The name a log line records, so the log reads without the sentence.
    public var logName: String {
        switch self {
        case .verified: "verified"
        case .verifiedWithRestriction: "verified_restricted"
        case .rejected: "rejected"
        case .serviceError: "service_error"
        case .unreachable: "unreachable"
        case .needsSetup: "needs_setup"
        case .unavailable: "unavailable"
        }
    }
}

/// A provider that can be asked whether its service accepts its credential.
///
/// This is deliberately not ``Provider/isAvailable()``: that question is asked
/// by the twenty-second provider refresh and by the record itself, and it has to
/// stay cheap, so for most providers it only answers whether a key is stored.
/// A verification costs one request and is only made when a page is on screen.
public protocol CredentialVerifying: Sendable {
    /// Sends the one request that proves the key and reads the answer.
    func verifyCredentials() async -> CredentialCheck
}

/// Sends the request that proves a credential, and maps the answer.
///
/// The request is the cheapest one a service documents that a key can read, and
/// it travels through ``HTTPTransport`` so an oversized answer cannot become
/// Dot's memory. Nothing here writes the key anywhere: the one log line a check
/// produces names the provider and the outcome, and the key stays in the header
/// of the request.
public enum CredentialVerifier {
    /// How long a check may take before it counts as unreachable.
    public static let timeout: TimeInterval = 8

    /// Builds one check request.
    ///
    /// - Parameters:
    ///   - url: the endpoint to call.
    ///   - method: the HTTP method the service documents.
    ///   - headers: every header the request carries, the credential included.
    ///   - body: the request body, when the service expects one.
    ///   - timeout: how long the request may take.
    /// - Returns: the request to send.
    public static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = timeout
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sends a check request and reads its status.
    ///
    /// A cancelled call answers with the value a failed transport produces, and
    /// the caller drops it: a check the page cancelled must not become a result
    /// the page shows.
    ///
    /// - Parameters:
    ///   - request: the request to send.
    ///   - session: the session to send it with.
    ///   - providerID: the provider the credential belongs to, for the log line.
    ///   - log: where the one line goes.
    /// - Returns: what the page shows beside the service.
    public static func check(
        _ request: URLRequest,
        session: URLSession,
        providerID: String,
        log: Log = .shared
    ) async -> CredentialCheck {
        let result: CredentialCheck
        do {
            let answer = try await HTTPTransport.send(request, session: session)
            guard let response = answer.response as? HTTPURLResponse else {
                result = .unreachable(unreachableMessage(for: request))
                return await record(result, providerID: providerID, log: log)
            }
            if (200 ..< 300).contains(response.statusCode) {
                result = .verified
            } else if response.statusCode == 401 || response.statusCode == 403 {
                // One service answers a 401 for a key it accepted but did not
                // grant the models read. The body is the only place it says
                // which refusal this is, so a 401 from that provider is read
                // before it is taken as a bad key.
                if response.statusCode == 401,
                   providerID == ProviderIdentifier.elevenLabs,
                   let restriction = elevenLabsRestriction(in: answer.data) {
                    result = .verifiedWithRestriction(restriction)
                } else {
                    result = .rejected(status: response.statusCode)
                }
            } else if response.statusCode == 429 || (500 ..< 600).contains(response.statusCode) {
                result = .serviceError(status: response.statusCode, host: request.url?.host ?? "the service")
            } else {
                result = .unreachable("The service answered \(response.statusCode).")
            }
        } catch {
            result = .unreachable(unreachableMessage(for: request))
        }
        return await record(result, providerID: providerID, log: log)
    }

    /// The sentence an ElevenLabs 401 carries when the key is accepted but not
    /// allowed to list models.
    static let elevenLabsRestrictionMessage =
        "ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use."

    /// What an ElevenLabs 401 body says about the key, when it is the
    /// permission refusal rather than a bad secret.
    ///
    /// A new ElevenLabs key starts with every permission switched off, and the
    /// models read is not needed to transcribe, so the common dictation-only
    /// key is answered 401 rather than 200. Two spellings carry the scope: the
    /// body's `detail.status` and its `detail.code`, and either one saying
    /// `missing_permissions` is the answer. Only those two fields are read: the
    /// body is never logged, never kept, and any other shape is `nil`, which
    /// leaves the 401 a refusal.
    ///
    /// - Parameter body: the answer's body.
    /// - Returns: the sentence for an accepted-but-restricted key, or `nil`.
    static func elevenLabsRestriction(in body: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: body),
              let object = payload as? [String: Any],
              let detail = object["detail"] as? [String: Any]
        else { return nil }
        let status = detail["status"] as? String
        let code = detail["code"] as? String
        guard status == "missing_permissions" || code == "missing_permissions" else {
            return nil
        }
        return elevenLabsRestrictionMessage
    }

    /// The sentence a request that never answered produces.
    ///
    /// - Parameter request: the request that did not complete.
    /// - Returns: the row's tooltip.
    public static func unreachableMessage(for request: URLRequest) -> String {
        "Can't reach \(request.url?.host ?? "the service")."
    }

    /// The key a request should carry, when there is one.
    ///
    /// A field that holds spaces is an empty field: sending those bytes would be
    /// answered with a refusal the person cannot act on.
    ///
    /// - Parameter apiKey: the key as the configuration or the page holds it.
    /// - Returns: the key without surrounding whitespace, or `nil` when there is
    ///   nothing to send.
    public static func credential(_ apiKey: String?) -> String? {
        guard let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The check that says a key is missing.
    ///
    /// - Parameter service: the service the key belongs to, named the way the
    ///   page names it.
    /// - Returns: the row's answer before any request is made.
    public static func missingKey(_ service: String) -> CredentialCheck {
        .needsSetup("Add an API key for \(service).")
    }

    /// Writes the one line a check produces.
    private static func record(
        _ check: CredentialCheck,
        providerID: String,
        log: Log
    ) async -> CredentialCheck {
        guard !Task.isCancelled else { return check }
        log.info("credential.checked", [
            "provider": .string(providerID),
            "result": .string(check.logName),
        ])
        return check
    }
}

/// An answered question and the moment it was answered.
///
/// The time travels with the answer: a row that reuses a fresh result says when
/// the service was asked, not when the page happened to open.
public struct CredentialCheckRecord: Sendable, Equatable {
    /// What the service said.
    public let check: CredentialCheck
    /// The moment the answer arrived.
    public let checkedAt: Date

    public init(check: CredentialCheck, checkedAt: Date) {
        self.check = check
        self.checkedAt = checkedAt
    }
}

/// Where a page's checks are kept.
///
/// The page asks this before it asks a service, and records what the service
/// said. It is a protocol so the moment between an answer and its publication
/// can be held open: a second question that arrives then is exactly the case a
/// page must not show the first answer over.
public protocol CredentialCheckCaching: Sendable {
    /// The result that is still fresh, when there is one.
    ///
    /// - Parameters:
    ///   - entry: the name the question is stored under.
    ///   - now: the moment the caller asks.
    /// - Returns: the answer and its time, or `nil` when none was stored or it
    ///   is too old.
    func result(for entry: String, now: Date) async -> CredentialCheckRecord?

    /// Records what a check found.
    ///
    /// - Parameters:
    ///   - check: what the service said.
    ///   - entry: the name the question is stored under.
    ///   - date: the moment the answer arrived.
    func store(_ check: CredentialCheck, for entry: String, at date: Date) async

    /// Drops the answer to a question.
    ///
    /// A page whose question was replaced while its answer was being written
    /// removes that answer: the cache must not offer it to a later check of the
    /// same question, because the page never accepted it.
    ///
    /// - Parameter entry: the name the question is stored under.
    func remove(_ entry: String) async
}

/// The checks this run of the app has already made.
///
/// Opening the page twice in a minute must not send the service two requests,
/// and a new launch checks again. The name a result is stored under is the
/// provider, the address it was asked at, and a digest of the key: a key that
/// was replaced or an endpoint that was moved is a different question, and the
/// key itself is never part of what is kept.
public actor CredentialCheckCache: CredentialCheckCaching {
    /// How long a result is reused.
    public static let lifetime: TimeInterval = 600

    /// The cache the page uses.
    public static let shared = CredentialCheckCache()

    private var results: [String: (check: CredentialCheck, at: Date)] = [:]

    public init() {}

    /// The name a result and a check share.
    ///
    /// Every input that changes the request is part of the name: the provider,
    /// the address, the header the key travels in, a digest of the key, and
    /// whatever else the provider's own state contributes (the on-device
    /// locale and asset). A cache entry therefore names one question, not a
    /// family of them.
    ///
    /// - Parameters:
    ///   - providerID: the provider the credential belongs to.
    ///   - baseURL: the address the request was sent to, when the provider has
    ///     one.
    ///   - authStyle: the header the key travels in, when the provider offers a
    ///     choice.
    ///   - credential: the key, or `nil` when the provider needs none.
    ///   - extra: any further state the provider's answer depends on.
    /// - Returns: the key a result is stored under.
    public static func entry(
        providerID: String,
        baseURL: String?,
        authStyle: String?,
        credential: String?,
        extra: String? = nil
    ) -> String {
        let address = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = providerID + " " + address + " " + (authStyle ?? "")
        name += " " + digest(credential)
        if let extra, !extra.isEmpty { name += " " + extra }
        return name
    }

    /// A short, stable fingerprint of a credential.
    ///
    /// It tells one key from another and cannot be turned back into the key it
    /// came from.
    ///
    /// - Parameter credential: the key, when there is one.
    /// - Returns: the first sixteen bytes of its SHA-256 in hexadecimal, or
    ///   `no-key`.
    static func digest(_ credential: String?) -> String {
        let clean = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clean.isEmpty else { return "no-key" }
        return SHA256.hash(data: Data(clean.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The result that is still fresh, when there is one.
    ///
    /// - Parameters:
    ///   - entry: the name ``entry(providerID:baseURL:authStyle:credential:extra:)``
    ///     built.
    ///   - now: the moment the caller asks.
    /// - Returns: the answer and the moment it arrived, or `nil` when none was
    ///   stored or it is older than ``lifetime``.
    public func result(for entry: String, now: Date = Date()) -> CredentialCheckRecord? {
        guard let stored = results[entry] else { return nil }
        guard now.timeIntervalSince(stored.at) < Self.lifetime else {
            results[entry] = nil
            return nil
        }
        return CredentialCheckRecord(check: stored.check, checkedAt: stored.at)
    }

    /// Records what a check found.
    public func store(_ check: CredentialCheck, for entry: String, at date: Date = Date()) {
        results[entry] = (check, date)
    }

    /// Drops the answer to a question.
    public func remove(_ entry: String) {
        results[entry] = nil
    }
}
