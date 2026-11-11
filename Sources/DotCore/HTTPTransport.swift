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
    /// Every failure is a ``ProviderError``: a transport problem keeps the
    /// message the system gave, and an oversized answer is reported as an
    /// unexpected answer rather than as silence.
    ///
    /// - Parameters:
    ///   - request: the request to send.
    ///   - session: the session to send it with.
    ///   - limit: the largest body that is accepted.
    /// - Returns: the body and the response.
    /// - Throws: ``ProviderError/transport(_:)`` when the request never made
    ///   it, ``ProviderError/invalidResponse(_:)`` when the answer is larger
    ///   than `limit`.
    public static func send(
        _ request: URLRequest,
        session: URLSession,
        limit: Int = maximumResponseBytes
    ) async throws -> Answer {
        let response: URLResponse
        let bytes: URLSession.AsyncBytes
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw ProviderError.transport(error.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
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
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            throw ProviderError.transport(error.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        return Answer(data: data, response: response)
    }
}
