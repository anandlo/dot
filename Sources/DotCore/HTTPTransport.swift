import Foundation
import os

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

        let delegate = BoundedDataDelegate(limit: max(0, limit))
        let task = session.dataTask(with: request)
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancelByCaller(task: task)
        }
    }

    private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct State {
            var response: URLResponse?
            var data = Data()
            var continuation: CheckedContinuation<Answer, Error>?
            var finished = false
            var cancelledByCaller = false
            var started = false
            var earlyFailure: Error?
        }

        private let limit: Int
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(limit: Int) {
            self.limit = limit
        }

        func start(task: URLSessionDataTask, continuation: CheckedContinuation<Answer, Error>) {
            enum StartOutcome {
                case fail(Error)
                case resume
            }

            let outcome = state.withLock { current -> StartOutcome in
                if current.cancelledByCaller {
                    current.finished = true
                    return .fail(CancellationError())
                } else if let earlyFailure = current.earlyFailure {
                    current.finished = true
                    return .fail(earlyFailure)
                } else {
                    current.continuation = continuation
                    current.started = true
                    return .resume
                }
            }
            switch outcome {
            case .fail(let error):
                continuation.resume(throwing: error)
            case .resume:
                task.resume()
            }
        }

        func cancelByCaller(task: URLSessionDataTask) {
            let continuation = state.withLock { current -> CheckedContinuation<Answer, Error>? in
                current.cancelledByCaller = true
                guard !current.finished else { return nil }
                current.finished = true
                let cont = current.continuation
                current.continuation = nil
                return cont
            }
            task.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if response.expectedContentLength > Int64(limit) {
                let continuation = state.withLock { current -> CheckedContinuation<Answer, Error>? in
                    guard !current.finished else { return nil }
                    current.finished = true
                    current.earlyFailure = ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                    let cont = current.continuation
                    current.continuation = nil
                    return cont
                }
                completionHandler(.cancel)
                continuation?.resume(throwing: ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer))
                return
            }

            state.withLock { current in
                guard !current.finished else { return }
                current.response = response
                if response.expectedContentLength > 0 {
                    current.data.reserveCapacity(min(limit, Int(response.expectedContentLength)))
                } else {
                    current.data.reserveCapacity(min(limit, 64 * 1024))
                }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let result = state.withLock { current -> (oversized: Bool, continuation: CheckedContinuation<Answer, Error>?) in
                guard !current.finished else { return (false, nil) }
                if current.data.count + chunk.count > limit {
                    current.finished = true
                    current.earlyFailure = ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                    let cont = current.continuation
                    current.continuation = nil
                    return (true, cont)
                }
                current.data.append(chunk)
                return (false, nil)
            }
            if result.oversized {
                dataTask.cancel()
                result.continuation?.resume(
                    throwing: ProviderError.invalidResponse(ProviderErrorText.oversizedAnswer)
                )
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let outcome = state.withLock { current -> (
                continuation: CheckedContinuation<Answer, Error>?,
                cancelled: Bool,
                response: URLResponse?,
                data: Data,
                earlyFailure: Error?
            ) in
                guard !current.finished else { return (nil, false, nil, Data(), nil) }
                current.finished = true
                let cont = current.continuation
                current.continuation = nil
                return (cont, current.cancelledByCaller, current.response, current.data, current.earlyFailure)
            }
            guard let continuation = outcome.continuation else { return }
            if outcome.cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            if let earlyFailure = outcome.earlyFailure {
                continuation.resume(throwing: earlyFailure)
                return
            }
            if let error {
                continuation.resume(throwing: ProviderError.transport(error.localizedDescription))
                return
            }
            guard let response = outcome.response else {
                continuation.resume(throwing: ProviderError.transport("missing HTTP response"))
                return
            }
            continuation.resume(returning: Answer(data: outcome.data, response: response))
        }
    }
}
