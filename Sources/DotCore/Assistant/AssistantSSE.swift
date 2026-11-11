import Foundation

/// One event a server sent on a `text/event-stream` response.
public struct SSEEvent: Sendable, Equatable {
    /// The `event:` field, when the stream names the event. Anthropic names
    /// every event; OpenAI's chat stream does not.
    public var name: String?
    /// The `data:` payload, with its lines joined by a newline.
    public var data: String

    public init(name: String? = nil, data: String) {
        self.name = name
        self.data = data
    }
}

/// The ceilings a streamed answer is read under.
///
/// A chat answer is much larger than a transcript, and a stream never ends by
/// itself: a broken server that keeps writing would be an unbounded read. Every
/// limit here fails the read instead of growing a buffer, exactly like
/// ``HTTPTransport/maximumResponseBytes`` does for a whole answer.
public struct AssistantStreamLimits: Sendable, Equatable {
    /// The longest single line. A streamed tool argument is one JSON fragment
    /// per line, so this is generous for a request and far from unbounded.
    public var maximumLineBytes: Int
    /// The largest event payload, after its `data:` lines are joined.
    public var maximumEventBytes: Int
    /// The largest streamed answer in total.
    public var maximumTotalBytes: Int
    /// How much of a failed answer is read, so the message can be shown.
    public var maximumErrorBytes: Int

    public init(
        maximumLineBytes: Int = 512 * 1024,
        maximumEventBytes: Int = 1024 * 1024,
        maximumTotalBytes: Int = 8 * 1024 * 1024,
        maximumErrorBytes: Int = 32 * 1024
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventBytes = maximumEventBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumErrorBytes = maximumErrorBytes
    }

    /// The limits a chat stream is read under.
    public static let `default` = AssistantStreamLimits()
}

/// Turns lines into server-sent events.
///
/// The framing rules are the ones every provider follows: a blank line
/// dispatches the event collected so far, a line starting with a colon is a
/// comment, `event:` names the event and `data:` adds one line to its payload.
/// A leading space after the colon is the field separator's, not the value's,
/// so it is removed.
///
/// Unknown fields (`id`, `retry`, and anything a future provider invents) are
/// ignored on purpose: Anthropic states that new event types may appear, so a
/// decoder that refused one would break on a valid stream.
public struct SSEDecoder: Sendable {
    private let limits: AssistantStreamLimits
    private var name: String?
    private var dataLines: [String] = []
    private var dataBytes = 0

    public init(limits: AssistantStreamLimits = .default) {
        self.limits = limits
    }

    /// Adds one line, and returns the event it completes.
    ///
    /// - Parameter line: the line without its terminator.
    /// - Returns: the event, when the line was the blank line that dispatches
    ///   one.
    /// - Throws: ``ProviderError/invalidResponse(_:)`` when an event grew past
    ///   ``AssistantStreamLimits/maximumEventBytes``.
    public mutating func consume(line: String) throws -> SSEEvent? {
        if line.isEmpty {
            return take()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var remainder = line[line.index(after: colon)...]
            if remainder.hasPrefix(" ") { remainder = remainder.dropFirst() }
            value = String(remainder)
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event":
            name = value
        case "data":
            let cost = value.utf8.count + 1
            dataBytes += cost
            guard dataBytes <= limits.maximumEventBytes else {
                throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
            }
            dataLines.append(value)
        default:
            break
        }
        return nil
    }

    /// Ends the stream and returns an event that was waiting for its blank
    /// line. A server that closes without one still sent its last event.
    public mutating func flush() -> SSEEvent? {
        take()
    }

    /// The event the collected fields describe, if they describe one.
    private mutating func take() -> SSEEvent? {
        let payload = dataLines.joined(separator: "\n")
        let eventName = name
        name = nil
        dataLines.removeAll(keepingCapacity: true)
        dataBytes = 0
        // An event with no data field carries nothing to act on.
        guard !payload.isEmpty else { return nil }
        return SSEEvent(name: eventName, data: payload)
    }

    /// Decodes a whole `text/event-stream` body.
    ///
    /// - Parameter text: the body of an answer that has already ended.
    /// - Returns: the events it carried, in order.
    public static func decode(_ text: String, limits: AssistantStreamLimits = .default) throws -> [SSEEvent] {
        var decoder = SSEDecoder(limits: limits)
        var events: [SSEEvent] = []
        for line in lineReader(text) {
            if let event = try decoder.consume(line: line) {
                events.append(event)
            }
        }
        if let event = decoder.flush() {
            events.append(event)
        }
        return events
    }

    /// The lines of a body.
    ///
    /// A carriage return is normalized first. Swift treats `\r\n` as one
    /// character, so splitting the text on `\n` without this leaves every CRLF
    /// line intact and the body decodes as a single line.
    static func lineReader(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

extension HTTPTransport {
    /// Streams a `text/event-stream` answer as events.
    ///
    /// This sits beside ``HTTPTransport/send(_:session:limit:)`` rather than
    /// inside it: a transcript is one body that fits under a ceiling, and a
    /// chat answer is an open stream. Changing `send` would give every speech
    /// request a code path it does not need.
    ///
    /// The request is refused before the stream is read when the answer is not
    /// a success, and the message the service sent is carried on
    /// ``ProviderError/rejected(status:message:)``. Cancelling the consuming
    /// task cancels the request.
    ///
    /// - Parameters:
    ///   - request: the request to send. Its address is the caller's, so it has
    ///     already been through ``EndpointPolicy``.
    ///   - session: the session to send it with.
    ///   - limits: the ceilings the read happens under.
    /// - Returns: the events, in the order the service sent them.
    public static func eventStream(
        _ request: URLRequest,
        session: URLSession,
        limits: AssistantStreamLimits = .default
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pump(request, session: session, limits: limits, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    // A cancelled request is the caller's decision, not a
                    // service failure, so it is not reported as one.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: transportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads one response and yields its events.
    private static func pump(
        _ request: URLRequest,
        session: URLSession,
        limits: AssistantStreamLimits,
        into continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    ) async throws {
        let response: URLResponse
        let bytes: URLSession.AsyncBytes
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("no HTTP status")
        }
        // Whatever ends the read, the connection is released here: a thrown
        // error, an oversized answer or a normal end all leave the same way.
        defer { bytes.task.cancel() }
        guard (200..<300).contains(http.statusCode) else {
            let message = await failureMessage(in: bytes, limit: limits.maximumErrorBytes)
            throw ProviderError.rejected(status: http.statusCode, message: message)
        }

        var decoder = SSEDecoder(limits: limits)
        var line: [UInt8] = []
        line.reserveCapacity(256)
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= limits.maximumTotalBytes else {
                throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
            }
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let event = try decoder.consume(line: text) {
                    continuation.yield(event)
                }
            } else {
                line.append(byte)
                guard line.count <= limits.maximumLineBytes else {
                    throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                }
            }
        }
        if !line.isEmpty {
            if line.last == 0x0D { line.removeLast() }
            if let event = try decoder.consume(line: String(decoding: line, as: UTF8.self)) {
                continuation.yield(event)
            }
        }
        if let event = decoder.flush() {
            continuation.yield(event)
        }
    }

    /// The message at the head of a failed answer.
    ///
    /// Only the head is read: the answer can be a page of markup, and the
    /// status code is the fact even when the body says nothing useful.
    private static func failureMessage(
        in bytes: URLSession.AsyncBytes,
        limit: Int
    ) async -> String? {
        var data = Data()
        data.reserveCapacity(min(limit, 4096))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            return nil
        }
        return AssistantWireError.message(in: data)
    }

    /// Maps any thrown error to the shape the card and the log show.
    private static func transportError(_ error: Error) -> Error {
        if let providerError = error as? ProviderError { return providerError }
        if let urlError = error as? URLError {
            return ProviderError.transport(urlError.localizedDescription)
        }
        return ProviderError.transport(error.localizedDescription)
    }
}

/// Reads the error shape the providers put on the wire.
enum AssistantWireError {
    /// Whether a streamed event is the service reporting a failure.
    ///
    /// OpenAI-compatible endpoints send `{"error": {...}}`; Anthropic sends
    /// `{"type": "error", "error": {...}}`. Both occur in the middle of a
    /// stream that started with a success status, so an adapter has to look for
    /// them on every event.
    static func indicatesError(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
        else { return false }
        if object["error"] != nil { return true }
        return object["type"] as? String == "error"
    }

    /// The message in a failed answer or a mid-stream error event.
    ///
    /// OpenAI and Anthropic both use `{"error": {"message": "..."}}`; a proxy
    /// can answer with `{"error": "..."}` or `{"message": "..."}`; anything
    /// else is read as text and capped.
    static func message(in data: Data) -> String? {
        if let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String,
                   let clean = ProviderErrorText.sanitized(message) {
                    return clean
                }
                if let type = error["type"] as? String,
                   let clean = ProviderErrorText.sanitized(type) {
                    return clean
                }
            }
            if let error = object["error"] as? String,
               let clean = ProviderErrorText.sanitized(error) {
                return clean
            }
            if let message = object["message"] as? String,
               let clean = ProviderErrorText.sanitized(message) {
                return clean
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return ProviderErrorText.sanitized(text)
    }
}
