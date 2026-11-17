import Foundation

/// Reads a service's answer with a ceiling on how much of it Dot will hold.
///
/// `URLSession.data(for:)` puts the whole body in memory before the caller sees
/// a byte of it. An endpoint that answers with a gigabyte — a broken server, a
/// proxy serving a page, a hostile host — would then be a gigabyte of Dot's
/// memory for a transcript of a sentence. The body is read here instead, and
/// the read stops at ``maximumResponseBytes``.
public enum HTTPTransport {
    /// The largest answer Dot reads.
    ///
    /// A transcript is kilobytes. The ceiling is four megabytes, which is
    /// generous for any shape a speech service answers with and small enough
    /// that an answer which breaks the rule fails instead of allocating.
    public static let maximumResponseBytes = 4 * 1024 * 1024

    /// The answer to one request.
    public struct Answer: Sendable {
        /// The body, at most ``maximumResponseBytes`` long.
        public let data: Data
        /// The response, with the status code on it.
        public let response: URLResponse

        public init(data: Data, response: URLResponse) {
            self.data = data
            self.response = response
        }
    }

    /// Sends `request` and reads the answer, refusing an oversized body.
    ///
    /// Every transport or protocol failure is a ``ProviderError``: a transport
    /// problem keeps the message the system gave, and an oversized answer is
    /// reported as an unexpected answer rather than as silence.
    ///
    /// Cancellation of the *caller's* task is the one thing that is not a
    /// transport failure: `URLSession` answers an aborted request with
    /// `URLError.cancelled`, and a task the caller cancelled gets
    /// ``CancellationError`` instead, so a take the caller stopped is never
    /// shown as a service that could not be reached. A request the session
    /// aborts on its own — an invalidated session, a `URLSessionTask` cancelled
    /// elsewhere — is a transport failure, because the caller never asked to
    /// stop.
    ///
    /// - Parameters:
    ///   - request: the request to send.
    ///   - session: the session to send it with.
    ///   - limit: the largest body that is accepted.
    /// - Returns: the body and the response.
    /// - Throws: ``ProviderError/transport(_:)`` when the request never made
    ///   it or the session cancelled it, ``ProviderError/invalidResponse(_:)``
    ///   when the answer is larger than `limit`, and ``CancellationError`` when
    ///   the caller's task was cancelled.
    public static func send(
        _ request: URLRequest,
        session: URLSession,
        limit: Int = maximumResponseBytes
    ) async throws -> Answer {
        try Task.checkCancellation()

        let response: URLResponse
        let bytes: URLSession.AsyncBytes
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw failure(error)
        }

        // A declared length past the ceiling is refused before a byte is read.
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
        }

        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                }
            }
        } catch {
            // The ceiling's own ``ProviderError`` is a protocol answer, not a
            // transport problem; everything else is decided by ``failure``.
            if Task.isCancelled { throw CancellationError() }
            if let providerError = error as? ProviderError { throw providerError }
            throw failure(error)
        }
        // An answer that arrived while the take was being cancelled is not a
        // success the caller asked for.
        try Task.checkCancellation()
        return Answer(data: data, response: response)
    }

    /// The error to report for a request that did not produce an answer.
    ///
    /// Cancellation of the caller's task is the only cancellation this type
    /// propagates: it is the caller's decision. Anything else — including
    /// `URLError.cancelled` from a session that was invalidated or a
    /// `URLSessionTask` cancelled by someone else — is a transport failure,
    /// because the caller never asked the take to stop.
    private static func failure(_ error: Error) -> any Error {
        if Task.isCancelled { return CancellationError() }
        return ProviderError.transport(error.localizedDescription)
    }
}
