import Foundation
import Network
import XCTest

@testable import DotCore

/// A tiny HTTP server the tests can talk to.
///
/// It answers with the responses it was given, one per request, and records
/// everything it received so the test can check the request the client built.
final class StubServer: @unchecked Sendable {
    /// One request the server received.
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

    /// One answer the server gives.
    struct Response: @unchecked Sendable {
        var status: Int
        var body: Data
        var contentType: String

        init(status: Int, json: String) {
            self.status = status
            self.body = Data(json.utf8)
            self.contentType = "application/json"
        }

        init(status: Int, body: Data, contentType: String = "application/json") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dot.stub.server")
    private let lock = NSLock()
    private var responses: [Response] = []
    private var received: [Received] = []
    private let fallback: Response

    /// The port the server listens on.
    private(set) var port: Int = 0

    init(responses: [Response], fallback: Response? = nil) throws {
        self.responses = responses
        self.fallback = fallback ?? Response(status: 500, json: #"{"code":"stub","message":"no stub left"}"#)
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
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "the stub server did not start")
        port = Int(listener.port?.rawValue ?? 0)
    }

    deinit {
        listener.cancel()
    }

    /// The requests the server has received so far.
    var requests: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let buffer = RequestBuffer()
        Self.read(connection: connection, buffer: buffer, server: self)
    }

    private static func read(connection: NWConnection, buffer: RequestBuffer, server: StubServer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let request = StubServer.parse(buffer.snapshot()) {
                server.record(request)
                let response = server.nextResponse()
                connection.send(content: response.data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read(connection: connection, buffer: buffer, server: server)
            }
        }
    }

    private func record(_ request: Received) {
        lock.lock()
        received.append(request)
        lock.unlock()
    }

    private func nextResponse() -> Response {
        lock.lock()
        defer { lock.unlock() }
        if responses.isEmpty { return fallback }
        return responses.removeFirst()
    }

    private static func parse(_ buffer: Data) -> Received? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let target = requestLine[1]
        let path: String
        let query: String
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            query = String(target[target.index(after: mark)...])
        } else {
            path = target
            query = ""
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = range.upperBound
        let contentLength = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return Received(method: method, path: path, query: query, headers: headers, body: body)
    }
}

/// Holds the bytes of a request while it is still arriving.
private final class RequestBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

extension StubServer.Response {
    /// The bytes that go on the wire.
    var data: Data {
        var head = "HTTP/1.1 \(status) \(StubServer.Response.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 401: "Unauthorized"
        case 408: "Request Timeout"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
