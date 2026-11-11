import Foundation
import Network
import XCTest

/// A loopback server that sends one answer in two pieces and refuses to send the
/// second until the test says so.
///
/// The ordinary ``StubServer`` answers in one write, which cannot tell a reader
/// that streams from a reader that buffers the whole body and returns it at the
/// end: both look the same from the client. Here the second piece is withheld, so
/// a chunk that arrives while it is withheld proves the reader is streaming. If
/// the reader waited for the connection to close, the test's first `next()` would
/// block until the release valve opens after five seconds.
final class TwoPartStubServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.stub.two-part")
    private let release = DispatchSemaphore(value: 0)
    private let head: Data
    private let tail: Data
    private let requests = RequestLog()

    /// The port the server listens on.
    private(set) var port: Int = 0

    /// Creates the server.
    ///
    /// - Parameters:
    ///   - first: the bytes sent with the headers.
    ///   - second: the bytes sent only after ``releaseSecondPart()``.
    ///   - status: the HTTP status to answer with.
    ///   - contentType: the content type of the body.
    init(first: Data, second: Data, status: Int = 200, contentType: String = "audio/pcm") throws {
        var header = "HTTP/1.1 \(status) OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(first.count + second.count)\r\n"
        header += "Connection: close\r\n\r\n"
        self.head = Data(header.utf8) + first
        self.tail = second
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the two-part server did not start")
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        release.signal()
        listener.cancel()
    }

    /// Lets the second piece of the answer go.
    func releaseSecondPart() {
        release.signal()
    }

    /// The request head the server received, for assertions.
    var requestText: String {
        requests.text
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.requests.record(accumulated)
                self.sendHead(connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer: accumulated)
        }
    }

    private func sendHead(_ connection: NWConnection) {
        connection.send(content: head, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            // The valve: a reader that buffered everything is released after
            // five seconds, so a broken streaming path fails a test instead of
            // hanging the suite.
            _ = self.release.wait(timeout: .now() + 5)
            connection.send(content: self.tail, completion: .contentProcessed { _ in
                connection.cancel()
            })
        })
    }
}

/// The request the two-part server received.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func record(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}
