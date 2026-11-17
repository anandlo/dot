import Foundation
import Network
import XCTest

@testable import DotCore

/// The one request that proves a key, per provider.
///
/// Every service is asked with the call its own documentation names: the method,
/// the path and the header are asserted here, so a check that quietly asked the
/// wrong endpoint, or put the key somewhere a proxy would log it, fails. The
/// answers are the four a real service gives: a success, a refusal, a failure
/// and silence.
final class CredentialCheckTests: XCTestCase {
    private let key = "sk-test-0123456789abcdef"
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - Success, refusal, failure

    func testEveryProviderIsVerifiedByASuccess() async throws {
        for probe in try probes() {
            let server = try StubServer(responses: [.init(status: 200, json: #"{"ok":true}"#)])
            let check = await probe.verify(server.port, session, 2)
            XCTAssertEqual(check, .verified, "\(probe.name) did not verify a 200 answer")
            let request = try XCTUnwrap(server.requests.first, "\(probe.name) sent no request")
            XCTAssertEqual(request.method, probe.method, "\(probe.name) used the wrong method")
            XCTAssertEqual(request.path, probe.path, "\(probe.name) asked the wrong path")
            XCTAssertEqual(
                request.header(probe.header),
                probe.headerValue(key),
                "\(probe.name) did not carry the key in \(probe.header)"
            )
            XCTAssertFalse(
                request.path.contains(key),
                "\(probe.name) put the key in the request line"
            )
            XCTAssertFalse(
                request.query.contains(key),
                "\(probe.name) put the key in the query string"
            )
            for (name, value) in request.headers where name.lowercased() != probe.header.lowercased() {
                XCTAssertFalse(
                    value.contains(key),
                    "\(probe.name) sent the key in \(name) as well as \(probe.header)"
                )
            }
            if probe.method == "POST" {
                XCTAssertTrue(request.body.isEmpty, "\(probe.name) sent a body to a token endpoint")
            }
        }
    }

    func testEveryProviderRejectsARefusedKey() async throws {
        for probe in try probes() {
            let server = try StubServer(responses: [.init(status: 401, json: #"{"error":"bad key"}"#)])
            let check = await probe.verify(server.port, session, 2)
            XCTAssertEqual(check, .rejected(status: 401), "\(probe.name) did not report a refused key")
            XCTAssertEqual(server.requests.count, 1)
        }
        for probe in try probes() {
            let server = try StubServer(responses: [.init(status: 403, json: "{}")])
            let check = await probe.verify(server.port, session, 2)
            XCTAssertEqual(check, .rejected(status: 403), "\(probe.name) did not report a forbidden key")
        }
    }

    func testEveryProviderReportsTheStatusCodeOfAnUnexpectedAnswer() async throws {
        for probe in try probes() {
            let server = try StubServer(responses: [.init(status: 404, json: "{}")])
            let check = await probe.verify(server.port, session, 2)
            XCTAssertEqual(check, .unreachable("The service answered 404."), "\(probe.name) hid the code")
        }
    }

    func testEveryProviderCallsA429OrA500AServiceError() async throws {
        for probe in try probes() {
            for status in [429, 500, 503] {
                let server = try StubServer(responses: [.init(status: status, json: "{}")])
                let check = await probe.verify(server.port, session, 2)
                XCTAssertEqual(
                    check,
                    .serviceError(status: status, host: "127.0.0.1"),
                    "\(probe.name) did not report \(status) as a service error"
                )
                XCTAssertEqual(check.title, "Service error")
                XCTAssertEqual(check.message, "HTTP \(status) from 127.0.0.1")
            }
        }
    }

    func testAForbiddenKeySaysWhatTheStatusMeans() {
        XCTAssertEqual(CredentialCheck.rejected(status: 401).message, "The service refused this key.")
        XCTAssertEqual(
            CredentialCheck.rejected(status: 403).message,
            "HTTP 403: the key was refused for this request"
        )
        XCTAssertEqual(CredentialCheck.rejected(status: 403).title, "Key rejected")
    }

    func testEveryProviderReportsSilenceAsUnreachable() async throws {
        for probe in try probes() {
            let server = try SilentServer()
            let check = await probe.verify(server.port, session, 0.3)
            XCTAssertEqual(
                check,
                .unreachable("Can't reach 127.0.0.1."),
                "\(probe.name) did not describe a timeout as an unreachable host"
            )
        }
    }

    // MARK: - ElevenLabs: an accepted key that may not list models

    /// The permission refusal is not a bad key.
    ///
    /// A new ElevenLabs key starts with every permission off, and the models
    /// read is not needed to transcribe, so the common dictation-only key is
    /// answered 401. The body's two fields are read because services have
    /// spelled the same refusal in either one.
    func testElevenLabsReadsAMissingModelsPermissionAsAVerifiedKey() async throws {
        let bodies = [
            #"{"detail":{"status":"missing_permissions"}}"#,
            #"{"detail":{"code":"missing_permissions"}}"#,
            #"{"detail":{"code":"unauthorized","status":"missing_permissions"}}"#,
        ]
        for body in bodies {
            let server = try StubServer(responses: [.init(status: 401, json: body)])
            let check = await elevenLabsCheck(server.port)
            XCTAssertEqual(
                check,
                .verifiedWithRestriction(CredentialVerifier.elevenLabsRestrictionMessage),
                body
            )
            XCTAssertEqual(check.title, "Verified", body)
            XCTAssertEqual(check.message, CredentialVerifier.elevenLabsRestrictionMessage, body)
        }
    }

    func testElevenLabsReadsAnInvalidKeyAsARefusal() async throws {
        let bodies = [
            #"{"detail":{"status":"invalid_api_key"}}"#,
            #"{"detail":{"code":"invalid_api_key"}}"#,
            #"{"detail":{"message":"bad key"}}"#,
        ]
        for body in bodies {
            let server = try StubServer(responses: [.init(status: 401, json: body)])
            let check = await elevenLabsCheck(server.port)
            XCTAssertEqual(check, .rejected(status: 401), body)
        }
    }

    func testAnUnparseableElevenLabs401IsARefusal() async throws {
        let server = try StubServer(responses: [.init(status: 401, json: "not a json body")])
        let check = await elevenLabsCheck(server.port)
        XCTAssertEqual(check, .rejected(status: 401))
    }

    /// The permission spelling is ElevenLabs' own, not a rule for every 401.
    func testAnotherServiceReadsTheSameBodyAsARefusal() async throws {
        let server = try StubServer(
            responses: [.init(status: 401, json: #"{"detail":{"status":"missing_permissions"}}"#)]
        )
        let check = await GroqProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: key,
            session: session,
            verificationTimeout: 2
        ).verifyCredentials()
        XCTAssertEqual(check, .rejected(status: 401))
    }

    func testAnElevenLabsForbiddenAnswerIsStillARefusal() async throws {
        let server = try StubServer(
            responses: [.init(status: 403, json: #"{"detail":{"status":"missing_permissions"}}"#)]
        )
        let check = await elevenLabsCheck(server.port)
        XCTAssertEqual(check, .rejected(status: 403))
    }

    /// The body says which permission is missing; it never reaches the log.
    func testAnElevenLabsRestrictionBodyIsNotLogged() async throws {
        let server = try StubServer(
            responses: [.init(
                status: 401,
                json: #"{"detail":{"status":"missing_permissions","message":"missing the permission models_read"}}"#
            )]
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-restriction-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Log()
        let url = directory.appendingPathComponent(Log.fileName)
        XCTAssertTrue(log.openFile(at: url))

        let request = ElevenLabsProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: key,
            verificationTimeout: 2
        ).credentialRequest()!
        let check = await CredentialVerifier.check(
            request,
            session: session,
            providerID: ProviderIdentifier.elevenLabs,
            log: log
        )
        XCTAssertEqual(check, .verifiedWithRestriction(CredentialVerifier.elevenLabsRestrictionMessage))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("credential.checked"), "the check logged nothing")
        XCTAssertFalse(text.contains("missing_permissions"), "the log carried the refusal body")
        XCTAssertFalse(text.contains("models_read"), "the log carried the refusal body")
    }

    /// Builds the ElevenLabs check against a loopback server.
    private func elevenLabsCheck(_ port: Int) async -> CredentialCheck {
        await ElevenLabsProvider(
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!,
            apiKey: key,
            session: session,
            verificationTimeout: 2
        ).verifyCredentials()
    }

    // MARK: - What the pages say before a request

    func testAProviderWithoutAKeyAsksForOneInsteadOfSendingAnEmptyHeader() async {
        let check = await GroqProvider(apiKey: nil).verifyCredentials()
        XCTAssertEqual(check, .needsSetup("Add an API key for Groq."))
        let xiaomi = await XiaomiASRProvider(apiKey: "  ").verifyCredentials()
        XCTAssertEqual(xiaomi, .needsSetup("Add an API key for Xiaomi ASR."))
        let deepgram = await DeepgramProvider(apiKey: nil).verifyCredentials()
        XCTAssertEqual(deepgram, .needsSetup("Add an API key for Deepgram."))
        let eleven = await ElevenLabsProvider(apiKey: nil).verifyCredentials()
        XCTAssertEqual(eleven, .needsSetup("Add an API key for ElevenLabs."))
        let azure = await AzureSpeechProvider(apiKey: nil).verifyCredentials()
        XCTAssertEqual(azure, .needsSetup("Add an API key for Azure Speech."))
    }

    // MARK: - Endpoints built from the stored address

    func testXiaomiAsksTheStoredAddressIncludingATokenPlanOne() {
        let tokenPlan = URL(string: "https://token-plan-cn.xiaomimimo.com/v1")!
        let provider = XiaomiASRProvider(baseURL: tokenPlan, apiKey: key)
        let request = provider.credentialRequest()
        XCTAssertEqual(request?.url?.absoluteString, "https://token-plan-cn.xiaomimimo.com/v1/models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")

        let hosted = XiaomiASRProvider(apiKey: key)
        XCTAssertEqual(
            hosted.credentialRequest()?.url?.absoluteString,
            "https://api.xiaomimimo.com/v1/models"
        )
    }

    func testGroqAsksTheDocumentedModelsEndpoint() {
        let provider = GroqProvider(apiKey: key)
        XCTAssertEqual(
            provider.credentialRequest()?.url?.absoluteString,
            "https://api.groq.com/openai/v1/models"
        )
        XCTAssertEqual(provider.credentialRequest()?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    }

    func testDeepgramAsksTheProjectsEndpointWithATokenHeader() {
        let provider = DeepgramProvider(apiKey: key)
        XCTAssertEqual(
            provider.credentialRequest()?.url?.absoluteString,
            "https://api.deepgram.com/v1/projects",
            "the projects list is at the API root, not under /listen"
        )
        XCTAssertEqual(provider.credentialRequest()?.value(forHTTPHeaderField: "Authorization"), "Token \(key)")

        let listen = DeepgramProvider(baseURL: URL(string: "https://api.deepgram.com/v1/listen")!, apiKey: key)
        XCTAssertEqual(listen.projectsURL.absoluteString, "https://api.deepgram.com/v1/projects")
    }

    func testElevenLabsAsksModelsWithItsOwnHeader() {
        let provider = ElevenLabsProvider(apiKey: key)
        XCTAssertEqual(
            provider.credentialRequest()?.url?.absoluteString,
            "https://api.elevenlabs.io/v1/models"
        )
        XCTAssertEqual(provider.credentialRequest()?.value(forHTTPHeaderField: "xi-api-key"), key)
        XCTAssertNil(provider.credentialRequest()?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleUsesTheConfiguredAuthHeader() {
        let bearer = OpenAICompatibleProvider(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: key
        )
        XCTAssertEqual(
            bearer.credentialRequest().url?.absoluteString,
            "https://api.openai.com/v1/models"
        )
        XCTAssertEqual(bearer.credentialRequest().value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")

        let apiKeyHeader = OpenAICompatibleProvider(
            baseURL: URL(string: "https://example.test/v1")!,
            apiKey: key,
            authStyle: .apiKey
        )
        XCTAssertEqual(apiKeyHeader.credentialRequest().value(forHTTPHeaderField: "api-key"), key)
        XCTAssertNil(apiKeyHeader.credentialRequest().value(forHTTPHeaderField: "Authorization"))

        let keyless = OpenAICompatibleProvider(baseURL: URL(string: "http://127.0.0.1:8765/v1")!)
        XCTAssertNil(
            keyless.credentialRequest().value(forHTTPHeaderField: "Authorization"),
            "a local endpoint without a key must be asked without a header"
        )
    }

    func testAzureAsksTheTokenEndpointOfTheConfiguredResource() {
        let regional = AzureSpeechProvider(region: "westeurope", apiKey: key)
        XCTAssertEqual(
            regional.credentialRequest()?.url?.absoluteString,
            "https://westeurope.api.cognitive.microsoft.com/sts/v1.0/issueToken"
        )
        XCTAssertEqual(regional.credentialRequest()?.httpMethod, "POST")
        XCTAssertEqual(
            regional.credentialRequest()?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"),
            key
        )

        let shippedEndpoint = AzureSpeechProvider(
            baseURL: AzureSpeechProvider.defaultBaseURL,
            region: "eastus",
            apiKey: key
        )
        XCTAssertEqual(
            shippedEndpoint.credentialRequest()?.url?.host,
            "eastus.api.cognitive.microsoft.com",
            "the default STT endpoint must not be mistaken for a token endpoint"
        )

        let subdomain = AzureSpeechProvider(
            baseURL: URL(string: "https://dot-speech.cognitiveservices.azure.com/speech/recognition/conversation/cognitiveservices/v1")!,
            region: "eastus",
            apiKey: key
        )
        XCTAssertEqual(
            subdomain.credentialRequest()?.url?.absoluteString,
            "https://dot-speech.cognitiveservices.azure.com/sts/v1.0/issueToken"
        )
    }

    // MARK: - Apple

    func testAppleDescribesThisMacRatherThanAService() async {
        let provider = AppleSpeechProvider(localeIdentifier: "en_US")
        let check = await provider.verifyCredentials()
        if #available(macOS 26.0, *) {
            switch check {
            case .verified:
                let available = await provider.isAvailable()
                XCTAssertTrue(available, "a verified on-device model is reported unavailable at record time")
            case .needsSetup(let message):
                XCTAssertTrue(message.hasPrefix("The on-device model for "), message)
                XCTAssertTrue(message.hasSuffix(" is not installed."), message)
            case .unavailable(let message):
                XCTAssertFalse(message.isEmpty)
            case .rejected, .serviceError, .unreachable, .verifiedWithRestriction:
                XCTFail("the on-device provider reported a network outcome")
            }
        } else {
            XCTAssertEqual(check, .unavailable("Needs macOS 26 or newer."))
        }
    }

    // MARK: - The key and the log

    func testTheKeyNeverAppearsInALogLine() async throws {
        let server = try StubServer(responses: [.init(status: 200, json: "{}")])
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-credential-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = Log()
        let url = directory.appendingPathComponent(Log.fileName)
        XCTAssertTrue(log.openFile(at: url))

        for probe in try probes() {
            let request = probe.request(server.port, 2)
            _ = await CredentialVerifier.check(request, session: session, providerID: probe.id, log: log)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "the check logged nothing at all")
        XCTAssertFalse(text.contains(key), "a log line carried the key")
        XCTAssertEqual(
            text.components(separatedBy: "credential.checked").count - 1,
            try probes().count,
            "a check did not write its one line"
        )
        for probe in try probes() {
            XCTAssertTrue(text.contains(probe.id), "the log does not name \(probe.id)")
        }
    }

    // MARK: - The cache

    func testAFreshResultIsReusedAndAnOldOneIsNot() async {
        let cache = CredentialCheckCache()
        let entry = CredentialCheckCache.entry(
            providerID: "groq",
            baseURL: "https://api.groq.com/openai/v1",
            authStyle: "bearer",
            credential: key
        )
        let now = Date()
        await cache.store(.verified, for: entry, at: now)
        let fresh = await cache.result(for: entry, now: now.addingTimeInterval(599))
        XCTAssertEqual(fresh?.check, .verified)
        XCTAssertEqual(
            fresh?.checkedAt,
            now,
            "a reused answer lost the moment it was checked"
        )
        let stale = await cache.result(for: entry, now: now.addingTimeInterval(601))
        XCTAssertNil(stale, "a result older than its lifetime was reused")
    }

    func testTheCacheEntryNamesTheProviderTheAddressAndAKeyDigestOnly() {
        let first = CredentialCheckCache.entry(providerID: "openai", baseURL: "https://a.test/v1", authStyle: "bearer", credential: "key-one")
        let second = CredentialCheckCache.entry(providerID: "openai", baseURL: "https://a.test/v1", authStyle: "bearer", credential: "key-two")
        let moved = CredentialCheckCache.entry(providerID: "openai", baseURL: "https://b.test/v1", authStyle: "bearer", credential: "key-one")
        let same = CredentialCheckCache.entry(providerID: "openai", baseURL: "https://a.test/v1", authStyle: "bearer", credential: "key-one")
        let restyled = CredentialCheckCache.entry(providerID: "openai", baseURL: "https://a.test/v1", authStyle: "api-key", credential: "key-one")
        let onDevice = CredentialCheckCache.entry(providerID: "apple", baseURL: nil, authStyle: nil, credential: nil, extra: "locale:en_US asset:installed")
        let reinstalled = CredentialCheckCache.entry(providerID: "apple", baseURL: nil, authStyle: nil, credential: nil, extra: "locale:en_US asset:supported")
        XCTAssertNotEqual(first, second, "two keys shared one cached answer")
        XCTAssertNotEqual(first, moved, "two addresses shared one cached answer")
        XCTAssertEqual(first, same, "the same question was asked under two names")
        XCTAssertNotEqual(first, restyled, "two auth headers shared one cached answer")
        XCTAssertNotEqual(onDevice, reinstalled, "two on-device asset states shared one cached answer")
        XCTAssertFalse(first.contains("key-one"), "the cache key carried the key itself")
        XCTAssertTrue(first.hasPrefix("openai https://a.test/v1 bearer "))
    }

    // MARK: - The probes

    /// One provider, its documented request, and the provider under test.
    private struct Probe {
        let name: String
        let id: String
        let method: String
        let path: String
        let header: String

        /// The header value the key travels in.
        let headerValue: (String) -> String
        /// Builds the provider pointed at the loopback server.
        let verify: (Int, URLSession, TimeInterval) async -> CredentialCheck
        /// The request the provider would send, for the log test.
        let request: (Int, TimeInterval) -> URLRequest
    }

    private func probes() throws -> [Probe] {
        func base(_ port: Int) -> URL {
            URL(string: "http://127.0.0.1:\(port)/v1")!
        }
        return [
            Probe(
                name: "OpenAI-compatible",
                id: ProviderIdentifier.openAI,
                method: "GET",
                path: "/v1/models",
                header: "Authorization",
                headerValue: { "Bearer \($0)" },
                verify: { port, session, timeout in
                    await OpenAICompatibleProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    OpenAICompatibleProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()
                }
            ),
            Probe(
                name: "Groq",
                id: ProviderIdentifier.groq,
                method: "GET",
                path: "/v1/models",
                header: "Authorization",
                headerValue: { "Bearer \($0)" },
                verify: { port, session, timeout in
                    await GroqProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    GroqProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()!
                }
            ),
            Probe(
                name: "Xiaomi",
                id: ProviderIdentifier.xiaomi,
                method: "GET",
                path: "/v1/models",
                header: "Authorization",
                headerValue: { "Bearer \($0)" },
                verify: { port, session, timeout in
                    await XiaomiASRProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    XiaomiASRProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()!
                }
            ),
            Probe(
                name: "Deepgram",
                id: ProviderIdentifier.deepgram,
                method: "GET",
                path: "/v1/projects",
                header: "Authorization",
                headerValue: { "Token \($0)" },
                verify: { port, session, timeout in
                    await DeepgramProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    DeepgramProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()!
                }
            ),
            Probe(
                name: "ElevenLabs",
                id: ProviderIdentifier.elevenLabs,
                method: "GET",
                path: "/v1/models",
                header: "xi-api-key",
                headerValue: { $0 },
                verify: { port, session, timeout in
                    await ElevenLabsProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    ElevenLabsProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()!
                }
            ),
            Probe(
                name: "Azure Speech",
                id: ProviderIdentifier.azure,
                method: "POST",
                path: "/sts/v1.0/issueToken",
                header: "Ocp-Apim-Subscription-Key",
                headerValue: { $0 },
                verify: { port, session, timeout in
                    await AzureSpeechProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        session: session,
                        verificationTimeout: timeout
                    ).verifyCredentials()
                },
                request: { port, timeout in
                    AzureSpeechProvider(
                        baseURL: base(port),
                        apiKey: self.key,
                        verificationTimeout: timeout
                    ).credentialRequest()!
                }
            ),
        ]
    }
}

/// A loopback server that accepts a connection and never answers.
///
/// The timeout case needs a request that is not refused and not completed: a
/// port with no listener fails at once with a connection error, which cannot
/// tell a deadline from a refusal.
final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.silent.server")

    /// The port the server listens on.
    private(set) var port: Int = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let queue = self.queue
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the silent server did not start")
        self.listener = listener
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        listener.cancel()
    }
}
