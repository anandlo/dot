import Foundation

/// Reads a text-to-speech answer as it arrives, with a ceiling on it.
///
/// ``HTTPTransport/send(_:session:limit:)`` hands back its body only when the
/// last byte is in: that is right for a transcript and wrong for speech, where
/// the first sentence must be audible while the service is still generating the
/// second. This reader is the sibling the audio path needs. It keeps the same
/// discipline as the transport it sits beside: the response is checked before a
/// byte of audio reaches the player, a failure body is read with its own small
/// cap so an HTML error page cannot be mistaken for audio, and the stream stops
/// at ``maximumAudioBytes`` instead of growing with the answer.
///
/// It is deliberately separate from ``HTTPTransport`` rather than a change to
/// it: the four speech providers keep the exact behaviour they were tested with.
public enum VoiceByteStream {
    /// The largest audio answer Dot reads.
    ///
    /// At 24 kHz mono PCM16 that is a little over five minutes of speech, which
    /// is longer than any answer Dot speaks, and small enough that a service
    /// which never stops sending cannot exhaust memory.
    public static let maximumAudioBytes = 16 * 1024 * 1024

    /// How many bytes are handed to the player at a time.
    ///
    /// 4 KB is about 85 ms at 24 kHz, small enough that playback starts on the
    /// first network chunk and large enough that the player is not scheduled
    /// thousands of times a second.
    public static let chunkBytes = 4096

    /// The most of a failure body that is read to explain the failure.
    public static let maximumErrorBytes = 8 * 1024

    /// Sends `request` and yields its audio as it arrives.
    ///
    /// - Parameters:
    ///   - request: the request to send.
    ///   - session: the session to send it with.
    ///   - format: the format the answer is declared to be in.
    ///   - limit: the largest answer that is accepted.
    /// - Returns: the audio chunks, in the order they arrived.
    /// - Throws: ``ProviderError/rejected(status:message:)`` when the service
    ///   refuses the request, ``ProviderError/transport(_:)`` when it cannot be
    ///   reached, ``ProviderError/invalidResponse(_:)`` when it answers with
    ///   more than `limit` bytes.
    public static func chunks(
        _ request: URLRequest,
        session: URLSession,
        format: VoiceAudioFormat,
        limit: Int = maximumAudioBytes
    ) async throws -> AsyncThrowingStream<VoiceChunk, Error> {
        let response: URLResponse
        let bytes: URLSession.AsyncBytes
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw ProviderError.transport(error.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("the answer had no status")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await prefix(bytes, limit: maximumErrorBytes)
            throw ProviderError.rejected(
                status: http.statusCode,
                message: VoiceErrorPayload.message(in: body)
            )
        }
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(chunkBytes)
                var total = 0
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        total += 1
                        if total > limit {
                            throw ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                        }
                        if buffer.count >= chunkBytes {
                            continuation.yield(VoiceChunk(data: buffer, format: format))
                            buffer = Data()
                            buffer.reserveCapacity(chunkBytes)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(VoiceChunk(data: buffer, format: format))
                    }
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: ProviderError.transport(error.localizedDescription)
                    )
                }
            }
            continuation.onTermination = { _ in
                // Stop reading, close the socket, and with it the vendor's
                // generation: a stopped answer must not keep costing money.
                task.cancel()
                bytes.task.cancel()
            }
        }
    }

    /// Reads at most `limit` bytes of a body.
    private static func prefix(
        _ bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 1024))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A failure body that cannot be read still leaves the status code,
            // which is the part of the explanation that matters.
            return data
        }
        return data
    }
}

/// The message a service put in a refused answer.
public enum VoiceErrorPayload {
    /// Pulls the human sentence out of a vendor's error body.
    ///
    /// Every vendor shapes its error differently, and a proxy in front of one
    /// answers with a page of HTML. The shapes Dot knows are `error.message`,
    /// `detail` (string or object), `message` and `error` as a string; anything
    /// else is returned as the head of the text, cleaned and capped by
    /// ``ProviderErrorText``.
    ///
    /// - Parameter data: the beginning of the failure body.
    /// - Returns: the message, or `nil` when the body says nothing.
    public static func message(in data: Data) -> String? {
        if let payload = try? JSONSerialization.jsonObject(with: data, options: []),
           let text = message(inJSON: payload) {
            return text
        }
        let text = String(decoding: data, as: UTF8.self)
        return ProviderErrorText.sanitized(text)
    }

    private static func message(inJSON payload: Any) -> String? {
        if let object = payload as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return ProviderErrorText.sanitized(message)
            }
            if let error = object["error"] as? String {
                return ProviderErrorText.sanitized(error)
            }
            if let detail = object["detail"] as? String {
                return ProviderErrorText.sanitized(detail)
            }
            if let detail = object["detail"] as? [String: Any],
               let message = detail["message"] as? String ?? detail["error"] as? String {
                return ProviderErrorText.sanitized(message)
            }
            if let message = object["message"] as? String {
                return ProviderErrorText.sanitized(message)
            }
        }
        if let array = payload as? [[String: Any]] {
            return array.compactMap { message(inJSON: $0) }.first
        }
        return nil
    }
}

/// The status check shared by the JSON-shaped voice requests.
public enum VoiceHTTP {
    /// Throws when an answer is not a success, with the service's own message.
    ///
    /// - Parameter answer: the body and response ``HTTPTransport`` returned.
    /// - Throws: ``ProviderError/rejected(status:message:)`` for a refusal,
    ///   ``ProviderError/invalidResponse(_:)`` when there is no HTTP status.
    public static func validate(_ answer: HTTPTransport.Answer) throws {
        guard let http = answer.response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("the answer had no status")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.rejected(
                status: http.statusCode,
                message: VoiceErrorPayload.message(in: answer.data)
            )
        }
    }
}
