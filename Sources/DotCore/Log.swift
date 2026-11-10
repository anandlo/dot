import Foundation

/// How important a log line is.
public enum LogLevel: String, Sendable, Comparable, CaseIterable {
    case debug
    case info
    case warn
    case error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A value in a log line.
public enum LogValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }
}

/// Writes JSON lines to `~/Library/Logs/Dot/Dot.log`.
///
/// The log never contains a secret: every API key is registered as a secret
/// the moment it is read, and every string that goes through the logger is
/// scrubbed.
public final class Log: @unchecked Sendable {
    /// The shared logger.
    public static let shared = Log()

    /// The name of the log file.
    public static let fileName = "Dot.log"
    /// The directory the log file lives in.
    public static let directoryName = "Library/Logs/Dot"

    /// The lines are rotated once the file grows past this size.
    public static let maximumBytes = 5_000_000
    /// How much of the file survives a rotation.
    public static let keptBytes = 1_000_000

    private let lock = NSLock()
    private var secrets: Set<String> = []
    private var minimumLevel: LogLevel = .info
    private var fileHandle: FileHandle?
    private var fileURL: URL?

    /// Creates a logger that starts with no file.
    public init() {}

    /// The directory the log file lives in.
    public static func directoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The full path of the log file.
    public static func defaultURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }

    /// The file the logger writes to, when it has one.
    public var url: URL? { fileURL }

    /// Sets the lowest level that is written.
    public func setLevel(_ level: LogLevel) {
        lock.lock()
        minimumLevel = level
        lock.unlock()
    }

    /// Starts writing to a file, creating the directory when needed.
    @discardableResult
    public func openFile(at url: URL = defaultURL()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            fileURL = url
            rotateIfNeededLocked()
            return true
        } catch {
            fileHandle = nil
            fileURL = nil
            return false
        }
    }

    /// Registers a value that must never appear in a log line.
    public func registerSecret(_ secret: String?) {
        guard let secret, secret.count >= 4 else { return }
        lock.lock()
        secrets.insert(secret)
        lock.unlock()
    }

    /// Replaces every registered secret in a string.
    public func redact(_ text: String) -> String {
        lock.lock()
        let known = secrets
        lock.unlock()
        var result = text
        for secret in known where !secret.isEmpty && result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }

    /// Writes a debug line.
    public func debug(_ event: String, _ fields: [String: LogValue] = [:]) {
        write(.debug, event, fields)
    }

    /// Writes an info line.
    public func info(_ event: String, _ fields: [String: LogValue] = [:]) {
        write(.info, event, fields)
    }

    /// Writes a warning line.
    public func warn(_ event: String, _ fields: [String: LogValue] = [:]) {
        write(.warn, event, fields)
    }

    /// Writes an error line.
    public func error(_ event: String, _ fields: [String: LogValue] = [:]) {
        write(.error, event, fields)
    }

    /// Writes one line.
    public func write(_ level: LogLevel, _ event: String, _ fields: [String: LogValue] = [:]) {
        lock.lock()
        let allowed = level >= minimumLevel
        lock.unlock()
        guard allowed else { return }

        var payload: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "event": event,
        ]
        for (key, value) in fields {
            switch value {
            case .string(let text): payload[key] = redact(text)
            case .int(let number): payload[key] = number
            case .double(let number): payload[key] = number
            case .bool(let flag): payload[key] = flag
            case .null: payload[key] = NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        lock.lock()
        defer { lock.unlock() }
        if let handle = fileHandle {
            rotateIfNeededLocked()
            handle.write(Data(line.utf8))
        }
    }

    private func rotateIfNeededLocked() {
        guard let fileURL, let handle = fileHandle else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > Self.maximumBytes else { return }
        let keep = min(Self.keptBytes, size)
        guard let data = try? Data(contentsOf: fileURL), data.count > keep else { return }
        let tail = data.suffix(keep)
        let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
        try? handle.close()
        try? data.subdata(in: start..<data.endIndex).write(to: fileURL)
        if let reopened = try? FileHandle(forWritingTo: fileURL) {
            _ = try? reopened.seekToEnd()
            fileHandle = reopened
        }
    }
}
