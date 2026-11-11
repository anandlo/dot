import Foundation
import Network
import XCTest

@testable import DotCore

/// A loopback server that answers with one event and then keeps the connection
/// open.
///
/// The repository's `StubServer` answers with a whole body and closes, which is
/// what most of these tests need. A cancellation test needs the opposite: a
/// response that never ends on its own, so ending promptly can only be the
/// client's doing.
final class AssistantStreamStub: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.assistant.stream.stub")
    private let response: Data
    private let holdSeconds: TimeInterval
    private(set) var port: Int = 0

    init(firstEvent: String, holdSeconds: TimeInterval = 30) throws {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n\r\n"
            + firstEvent
        response = Data(head.utf8)
        self.holdSeconds = holdSeconds
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
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the stream stub did not start")
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection: connection, buffer: Data())
    }

    /// Waits for the request head, then answers.
    ///
    /// Sending an answer before the request has arrived can reset the
    /// connection, so the head is waited for and its body ignored.
    private func read(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var complete = buffer
            if let data { complete.append(data) }
            if complete.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete, error == nil {
                self.read(connection: connection, buffer: complete)
                return
            }
            connection.send(content: self.response, completion: .contentProcessed { _ in
                // Held open on purpose: a reader that was not cancelled is
                // still waiting when the test asserts.
                self.queue.asyncAfter(deadline: .now() + self.holdSeconds) {
                    connection.cancel()
                }
            })
        }
    }
}
