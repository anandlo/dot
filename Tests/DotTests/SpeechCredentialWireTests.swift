import AppKit
import DotCore
import Network
import os
import SwiftUI
import XCTest

@testable import Dot

/// The status label's whole vocabulary.
///
/// Every word the label can show, and the sentence behind it. The table is the
/// contract: a state that loses its title, its colour, or the time it was
/// checked would be a state a reader cannot tell from another.
@MainActor
final class SpeechCredentialStatusTests: XCTestCase {
    /// A local midnight: the clock is the reader's, so the fixture is not UTC.
    private let checkedAt = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 5, day: 19, hour: 0, minute: 0)
    )!

    func testTheStatusTableSpeaksEveryState() {
        let states: [(status: SpeechCredentialStatus, title: String, tone: Color, needsClock: Bool)] = [
            (.checking, "Checking", DotTheme.ink3, false),
            (.settled(.verified, checkedAt: checkedAt), "Verified", DotTheme.switchOn, true),
            (
                .settled(
                    .verifiedWithRestriction("ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use."),
                    checkedAt: checkedAt
                ),
                "Verified",
                DotTheme.switchOn,
                true
            ),
            (.settled(.rejected(status: 401), checkedAt: checkedAt), "Key rejected", DotTheme.coral, true),
            (.settled(.rejected(status: 403), checkedAt: checkedAt), "Key rejected", DotTheme.coral, true),
            (.settled(.serviceError(status: 429, host: "api.example.test"), checkedAt: checkedAt), "Service error", DotTheme.coral, true),
            (.settled(.serviceError(status: 503, host: "api.example.test"), checkedAt: checkedAt), "Service error", DotTheme.coral, true),
            (.settled(.unreachable("Can't reach api.example.test."), checkedAt: checkedAt), "Can't reach service", DotTheme.coral, false),
            (.settled(.needsSetup("Add an API key for Groq."), checkedAt: checkedAt), "Needs setup", DotTheme.amber, false),
            (.settled(.unavailable("Needs macOS 26 or newer."), checkedAt: checkedAt), "Unavailable", DotTheme.ink3, false),
            (.notSaved("The Keychain did not give the key back."), "Key not saved", DotTheme.coral, false),
        ]
        for state in states {
            XCTAssertEqual(state.status.title, state.title)
            XCTAssertEqual(state.status.tone, state.tone, "\(state.title) lost its colour")
            let hasClock = state.status.message.contains("Checked at ")
            XCTAssertEqual(hasClock, state.needsClock, "\(state.title) carries the wrong time line")
            if state.needsClock {
                XCTAssertNotNil(
                    state.status.message.range(of: #"Checked at \d\d:\d\d"#, options: .regularExpression),
                    "\(state.title) does not say when it was checked: \(state.status.message)"
                )
            }
        }
    }

    func testARefusalAndAServiceErrorSayWhatTheStatusCodeMeans() {
        XCTAssertEqual(
            SpeechCredentialStatus.settled(.rejected(status: 401), checkedAt: checkedAt).message,
            "The service refused this key.\nChecked at 00:00"
        )
        XCTAssertEqual(
            SpeechCredentialStatus.settled(.rejected(status: 403), checkedAt: checkedAt).message,
            "HTTP 403: the key was refused for this request\nChecked at 00:00"
        )
        XCTAssertEqual(
            SpeechCredentialStatus.settled(
                .serviceError(status: 503, host: "api.example.test"),
                checkedAt: checkedAt
            ).message,
            "HTTP 503 from api.example.test\nChecked at 00:00"
        )
        XCTAssertEqual(
            SpeechCredentialStatus.settled(.unreachable("Can't reach api.example.test."), checkedAt: checkedAt).message,
            "Can't reach api.example.test.",
            "a host that could not be reached is not given a check time"
        )
        XCTAssertEqual(
            SpeechCredentialStatus.settled(
                .verifiedWithRestriction("ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use."),
                checkedAt: checkedAt
            ).message,
            "ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use.\nChecked at 00:00",
            "an accepted-but-restricted key is still a check with a time"
        )
    }

    /// The clock the row prints is a wall clock, not a locale-shaped one.
    func testTheClockIsHoursAndMinutes() {
        XCTAssertEqual(SpeechCredentialStatus.clock(checkedAt), "00:00")
    }
}

/// The checks themselves, against loopback servers.
///
/// Three things are measured here that no single service can show on its own:
/// what a check sends when the page has a typed key for another service, that a
/// changed auth header misses the cache, and that a result which arrives after
/// its question was replaced is dropped.
@MainActor
final class SpeechCredentialWireTests: XCTestCase {
    private let providerKey = "sk-provider-stored-0123456789"
    private let foreignKey = "sk-foreign-typed-0123456789"

    override func setUp() {
        super.setUp()
        DotType.registerFonts(at: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    /// A check for a service carries that service's stored key, never text that
    /// was typed for the service before it.
    func testACheckForAServiceNeverCarriesAnotherServicesTypedKey() async throws {
        let server = try LoopbackStub(status: 200)
        let checks = SpeechCredentialChecks(
            cache: seededCache(providerID: ProviderIdentifier.groq, key: providerKey),
            checkCache: CredentialCheckCache()
        )
        let config = groqConfig(port: server.port)

        // The hazardous call: the text typed for the previous service handed to
        // this one. It must reach the wire, so the test can see it and the guard
        // below means something.
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: config,
            typedKey: foreignKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let sentForeign = await waitFor { server.requests.count == 1 }
        XCTAssertTrue(sentForeign, "the hazardous check sent nothing")
        XCTAssertEqual(server.requests.first?.header("Authorization"), "Bearer \(foreignKey)")

        // The page's path after a pick: no typed key at all.
        server.reset()
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: config,
            typedKey: nil,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let sentOwn = await waitFor { server.requests.count == 1 }
        XCTAssertTrue(sentOwn, "the check sent nothing")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.header("Authorization"), "Bearer \(providerKey)")
        for (name, value) in request.headers {
            XCTAssertFalse(value.contains(foreignKey), "\(name) carried the other service's typed key")
        }
        XCTAssertFalse(request.path.contains(foreignKey))
        XCTAssertFalse(request.query.contains(foreignKey))
    }

    /// Changing the header the key travels in is a new question, so the cache
    /// does not answer it.
    func testAChangedAuthStyleMissesTheCacheAndAsksAgain() async throws {
        let server = try LoopbackStub(status: 200)
        let checks = SpeechCredentialChecks(
            cache: seededCache(providerID: ProviderIdentifier.openAI, key: providerKey),
            checkCache: CredentialCheckCache()
        )
        var config = customConfig(port: server.port)
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.authStyle = .bearer
        config.providers[ProviderIdentifier.openAI] = settings

        checks.check(
            providerID: ProviderIdentifier.openAI,
            config: config,
            typedKey: nil,
            serviceName: "Custom endpoint",
            requiresKey: false,
            immediate: true
        )
        let first = await waitFor { server.requests.count == 1 }
        XCTAssertTrue(first, "the bearer check sent nothing")
        XCTAssertEqual(server.requests.first?.header("Authorization"), "Bearer \(providerKey)")

        settings.authStyle = .apiKey
        config.providers[ProviderIdentifier.openAI] = settings
        checks.check(
            providerID: ProviderIdentifier.openAI,
            config: config,
            typedKey: nil,
            serviceName: "Custom endpoint",
            requiresKey: false,
            immediate: true
        )
        let second = await waitFor { server.requests.count == 2 }
        XCTAssertTrue(second, "the api-key check was answered from the bearer cache entry")
        XCTAssertEqual(server.requests.last?.header("api-key"), providerKey)
        XCTAssertNil(server.requests.last?.header("Authorization"))
    }

    /// A result whose question has been replaced is not shown.
    func testALateResultIsDroppedWhenTheQuestionChanged() async throws {
        let slow = try DelayServer(delay: 0.4, status: 401)
        let fast = try LoopbackStub(status: 200)
        let key = providerKey
        let checks = SpeechCredentialChecks(
            cache: CredentialCache(reader: { _ in .key(key) }, logsReads: false),
            checkCache: CredentialCheckCache()
        )

        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: slow.port),
            typedKey: nil,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        try? await Task.sleep(for: .milliseconds(60))
        checks.check(
            providerID: ProviderIdentifier.deepgram,
            config: deepgramConfig(port: fast.port),
            typedKey: nil,
            serviceName: "Deepgram",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "the second check did not answer: \(checks.status.title)")

        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            checks.status.title,
            "Verified",
            "the first check's late refusal replaced the answer of the question that replaced it"
        )
    }

    /// An answer that arrives while its question is being replaced is not shown,
    /// even when the replacement finishes first.
    ///
    /// The test above replaces the question while the request is in flight.
    /// This one replaces it while the answer is being written down: the cache is
    /// held open after the first answer, the second question is asked and
    /// answered, and only then is the first answer allowed to continue. It must
    /// not land on the row that now describes the second question.
    func testAnAnswerThatArrivesAfterItsQuestionWasReplacedIsNotShown() async throws {
        let first = try LoopbackStub(status: 401)
        let second = try LoopbackStub(status: 200)
        let held = HeldCheckCache()
        let key = providerKey
        let checks = SpeechCredentialChecks(
            cache: CredentialCache(reader: { _ in .key(key) }, logsReads: false),
            checkCache: held
        )

        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: first.port),
            typedKey: nil,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let heldOpen = await waitFor(within: 5) { await held.entered }
        XCTAssertTrue(heldOpen, "the first answer was never written to the cache")
        XCTAssertEqual(checks.status, .checking, "the first answer was published before it was stored")

        checks.check(
            providerID: ProviderIdentifier.deepgram,
            config: deepgramConfig(port: second.port),
            typedKey: nil,
            serviceName: "Deepgram",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "the second question was never answered: \(checks.status.title)")

        await held.releaseFirstStore()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            checks.status.title,
            "Verified",
            "the replaced question's answer was published after the replacement answered"
        )
    }

    // MARK: - A key that is typed but not saved

    /// A working typed key is not "Verified": dictation cannot use it yet.
    func testAWorkingTypedKeyIsShownAsNotSaved() async throws {
        let server = try LoopbackStub(status: 200)
        let checks = SpeechCredentialChecks(
            cache: seededCache(providerID: ProviderIdentifier.groq, key: providerKey),
            checkCache: CredentialCheckCache()
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: server.port),
            typedKey: foreignKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Key not saved" }
        XCTAssertTrue(answered, "a working typed key was reported as saved: \(checks.status.title)")
        XCTAssertEqual(checks.status, .notSaved("The key works. Save it to use it."))
        XCTAssertEqual(checks.status.tone, DotTheme.coral)
    }

    /// A refused typed key is still not saved, with the refusal as its help.
    func testARefusedTypedKeyIsShownAsNotSaved() async throws {
        let server = try LoopbackStub(status: 401)
        let checks = SpeechCredentialChecks(
            cache: seededCache(providerID: ProviderIdentifier.groq, key: providerKey),
            checkCache: CredentialCheckCache()
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: server.port),
            typedKey: foreignKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Key not saved" }
        XCTAssertTrue(answered, "a refused typed key was reported as saved: \(checks.status.title)")
        XCTAssertEqual(checks.status, .notSaved("The service refused this key."))
    }

    /// Text that happens to be the stored key is not an unsaved change.
    func testATypedKeyThatMatchesTheStoredKeyIsVerified() async throws {
        let server = try LoopbackStub(status: 200)
        let checks = SpeechCredentialChecks(
            cache: seededCache(providerID: ProviderIdentifier.groq, key: providerKey),
            checkCache: CredentialCheckCache()
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: server.port),
            typedKey: providerKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "the stored key retyped was reported as unsaved: \(checks.status.title)")
        guard case .settled(.verified, _) = checks.status else {
            return XCTFail("the stored key retyped did not verify: \(checks.status)")
        }
    }

    // MARK: - The stored key when the read does not answer

    /// A read that timed out is not a difference.
    ///
    /// The text in the field is the stored key, but the read did not finish, so
    /// the page cannot know that. The row shows the plain answer instead of
    /// claiming a key that is stored is not saved.
    func testATypedKeyWhoseStoredReadTimesOutIsVerified() async throws {
        let server = try LoopbackStub(status: 200)
        let storedKey = providerKey
        let checks = SpeechCredentialChecks(
            cache: CredentialCache(reader: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .key(storedKey)
            }, logsReads: false),
            checkCache: CredentialCheckCache(),
            keyDeadline: .milliseconds(60)
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: server.port),
            typedKey: storedKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "a timed-out stored read became \(checks.status)")
        guard case .settled(.verified, _) = checks.status else {
            return XCTFail("a timed-out stored read was compared as if it had answered: \(checks.status)")
        }
    }

    /// A failed read is not a difference either.
    func testATypedKeyWhoseStoredReadFailedIsVerified() async throws {
        let server = try LoopbackStub(status: 200)
        let checks = SpeechCredentialChecks(
            cache: CredentialCache(
                reader: { _ in .failed("The Keychain refused the read.") },
                logsReads: false
            ),
            checkCache: CredentialCheckCache()
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: server.port),
            typedKey: foreignKey,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "a failed stored read became \(checks.status)")
        guard case .settled(.verified, _) = checks.status else {
            return XCTFail("a failed stored read was compared as if it had answered: \(checks.status)")
        }
    }

    // MARK: - A question replaced while its answer is stored

    /// The answer to a question the page abandoned is not left in the cache.
    ///
    /// The late-publication test above shows that the row is not written. This
    /// one shows the other half: the cache is not written either, so a later
    /// check of the replaced question asks the service instead of trusting an
    /// answer the page never accepted.
    func testAReplacedQuestionIsRemovedFromTheCache() async throws {
        let first = try LoopbackStub(status: 401)
        let second = try LoopbackStub(status: 200)
        let held = HeldCheckCache()
        let key = providerKey
        let checks = SpeechCredentialChecks(
            cache: CredentialCache(reader: { _ in .key(key) }, logsReads: false),
            checkCache: held
        )
        checks.check(
            providerID: ProviderIdentifier.groq,
            config: groqConfig(port: first.port),
            typedKey: nil,
            serviceName: "Groq",
            requiresKey: true,
            immediate: true
        )
        let heldOpen = await waitFor(within: 5) { await held.entered }
        XCTAssertTrue(heldOpen, "the first answer was never written to the cache")
        let storedBefore = await held.stored
        let replaced = try XCTUnwrap(storedBefore.first, "the first answer was not stored at all")

        checks.check(
            providerID: ProviderIdentifier.deepgram,
            config: deepgramConfig(port: second.port),
            typedKey: nil,
            serviceName: "Deepgram",
            requiresKey: true,
            immediate: true
        )
        let answered = await waitFor { checks.status.title == "Verified" }
        XCTAssertTrue(answered, "the second question was never answered: \(checks.status.title)")

        await held.releaseFirstStore()
        try? await Task.sleep(for: .milliseconds(300))

        let removed = await held.removed
        let stored = await held.stored
        XCTAssertEqual(removed, [replaced], "the replaced question's answer was not removed")
        XCTAssertFalse(stored.contains(replaced), "the cache kept an answer the page abandoned")
    }

    // MARK: - Fixtures

    private func seededCache(providerID: String, key: String) -> CredentialCache {
        CredentialCache(
            reader: { id in id == providerID ? .key(key) : .missing },
            logsReads: false
        )
    }

    private func customConfig(port: Int) -> DotConfig {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = "http://127.0.0.1:\(port)/v1"
        settings.language = nil
        config.providers[ProviderIdentifier.openAI] = settings
        return config
    }

    private func groqConfig(port: Int) -> DotConfig {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.groq)
        settings.baseURL = "http://127.0.0.1:\(port)/openai/v1"
        settings.language = nil
        config.providers[ProviderIdentifier.groq] = settings
        return config
    }

    private func deepgramConfig(port: Int) -> DotConfig {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.deepgram)
        settings.baseURL = "http://127.0.0.1:\(port)/v1"
        settings.language = nil
        config.providers[ProviderIdentifier.deepgram] = settings
        return config
    }

    /// Waits for a state to hold, looking between runloop turns.
    private func waitFor(
        within limit: TimeInterval = 3,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

/// A check cache that holds the first answer open until the test releases it.
///
/// It is the seam the page's generation counter needs: the answer is real, the
/// store has happened, and the row has not been given the answer yet.
actor HeldCheckCache: CredentialCheckCaching {
    /// Whether an answer is inside `store` and waiting.
    private(set) var entered = false
    private(set) var stored: [String] = []
    private(set) var removed: [String] = []
    private var heldOnce = false
    private var release: CheckedContinuation<Void, Never>?

    func result(for entry: String, now: Date) async -> CredentialCheckRecord? { nil }

    func store(_ check: CredentialCheck, for entry: String, at date: Date) async {
        stored.append(entry)
        guard !heldOnce else { return }
        heldOnce = true
        entered = true
        await withCheckedContinuation { continuation in
            release = continuation
        }
    }

    func remove(_ entry: String) async {
        removed.append(entry)
        stored.removeAll { $0 == entry }
    }

    /// Lets the first answer finish being written.
    func releaseFirstStore() {
        release?.resume()
        release = nil
    }
}

/// A loopback server that answers every request at once and keeps what it saw.
final class LoopbackStub: @unchecked Sendable {
    struct Received: @unchecked Sendable {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.loopback.stub")
    private let lock = NSLock()
    private var recorded: [Received] = []
    private let status: Int

    private(set) var port: Int = 0

    init(status: Int = 200) throws {
        self.status = status
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let queue = self.queue
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            LoopbackStub.read(connection: connection, buffer: Data(), server: self)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the loopback stub did not start")
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        listener.cancel()
    }

    var requests: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    fileprivate func record(_ request: Received) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    private static func read(connection: NWConnection, buffer: Data, server: LoopbackStub?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                read(connection: connection, buffer: buffer, server: server)
                return
            }
            let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.isEmpty ? [] : lines.removeFirst().components(separatedBy: " ")
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
            let bodyStart = separator.upperBound
            if buffer.count < bodyStart + length {
                read(connection: connection, buffer: buffer, server: server)
                return
            }
            let target = requestLine.count > 1 ? requestLine[1] : ""
            let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
            let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
            server?.record(Received(
                method: requestLine.first ?? "",
                path: path,
                query: query,
                headers: headers,
                body: buffer.subdata(in: bodyStart..<(bodyStart + length))
            ))
            let body = Data("{}".utf8)
            var response = "HTTP/1.1 \(server?.status ?? 200) Answer\r\n"
            response += "Content-Type: application/json\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Connection: close\r\n\r\n"
            var out = Data(response.utf8)
            out.append(body)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// A loopback server that answers one request after a pause.
final class DelayServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.delay.server")
    private let delay: TimeInterval
    private let status: Int

    private(set) var port: Int = 0

    init(delay: TimeInterval, status: Int) throws {
        self.delay = delay
        self.status = status
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let queue = self.queue
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [delay, status] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                queue.asyncAfter(deadline: .now() + delay) {
                    let body = Data("{}".utf8)
                    var head = "HTTP/1.1 \(status) Answer\r\n"
                    head += "Content-Type: application/json\r\n"
                    head += "Content-Length: \(body.count)\r\n"
                    head += "Connection: close\r\n\r\n"
                    var out = Data(head.utf8)
                    out.append(body)
                    connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the delay server did not start")
        self.listener = listener
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        listener.cancel()
    }
}

extension SpeechCredentialWireTests {
    func testKeylessAppleCheckPerformsZeroKeychainReads() async throws {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let cache = CredentialCache(reader: { _ in
            counter.withLock { $0 += 1 }
            return .missing
        }, logsReads: false)
        let checks = SpeechCredentialChecks(cache: cache, checkCache: CredentialCheckCache())
        var config = DotConfig.default
        config.provider = ProviderIdentifier.apple

        checks.check(
            providerID: ProviderIdentifier.apple,
            config: config,
            typedKey: nil,
            serviceName: "Apple Speech",
            requiresKey: false,
            allowsKey: false,
            immediate: true
        )
        for _ in 0..<20 {
            if checks.status != SpeechCredentialStatus.checking { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(counter.withLock { $0 }, 0, "allowsKey: false touched the Keychain reader")
    }
}
