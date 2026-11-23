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
///
/// The file is `0600` in a folder that is `0700`. It names the apps a person
/// dictated into and the endpoints their speech was sent to, which is not a
/// thing every other account on the Mac should be able to read.
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

    /// The timestamp format of every line.
    ///
    /// A format style is a value, so one is shared instead of building an
    /// `ISO8601DateFormatter` per line. Allocating one of those on every write
    /// was the most expensive part of writing a line.
    private static let timestamp = Date.ISO8601FormatStyle()

    private let lock = NSLock()
    private var secrets: Set<String> = []
    private var minimumLevel: LogLevel = .info
    /// Whether a file is open, readable from any thread without the writer's
    /// queue. It is what keeps a line from being built for a logger with
    /// nowhere to put it.
    private var hasFile = false
    /// Serialises the file work: opening, writing and the rotation.
    ///
    /// A line is written on paths a person is waiting on — the press that starts
    /// a recording, the frame that draws the card — so the payload is built on
    /// the caller and the file is touched here. One queue also keeps the lines in
    /// the order they were produced.
    private let queue = DispatchQueue(label: "com.anandlo.dot.log", qos: .utility)
    /// The writer's own state, touched only on `queue`.
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    /// How many bytes the file holds, as far as this logger wrote them.
    ///
    /// It is what makes a rotation check arithmetic instead of a `stat` call on
    /// every line: the size on disk is only read when the file is opened.
    private var writtenBytes = 0
    /// The size the file is rotated at.
    private let limitBytes: Int
    /// How much of the file survives a rotation.
    private let retainBytes: Int

    /// Creates a logger that starts with no file.
    public init() {
        self.limitBytes = Self.maximumBytes
        self.retainBytes = Self.keptBytes
    }

    /// Creates a logger with a file size of its own, for a test that has to
    /// rotate a small file instead of five megabytes of one.
    init(limitBytes: Int, retainBytes: Int) {
        self.limitBytes = max(256, limitBytes)
        self.retainBytes = max(0, min(retainBytes, self.limitBytes / 2))
    }

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
    public var url: URL? {
        queue.sync { fileURL }
    }

    /// Sets the lowest level that is written.
    public func setLevel(_ level: LogLevel) {
        lock.lock()
        minimumLevel = level
        lock.unlock()
    }

    /// Starts writing to a file, creating the directory when needed.
    @discardableResult
    public func openFile(at url: URL = defaultURL()) -> Bool {
        queue.sync {
            do {
                try SecureFile.createDirectory(at: url.deletingLastPathComponent())
                if !FileManager.default.fileExists(atPath: url.path) {
                    let descriptor = open(
                        url.path,
                        O_WRONLY | O_CREAT | O_APPEND,
                        mode_t(SecureFile.filePermissions)
                    )
                    guard descriptor >= 0 else { throw SecureFileError.cannotCreate(url.path) }
                    close(descriptor)
                }
                // A log an older build wrote is still `0644`.
                SecureFile.tighten(url)
                let handle = try FileHandle(forWritingTo: url)
                let end = try handle.seekToEnd()
                fileHandle = handle
                fileURL = url
                writtenBytes = Int(end)
                setHasFile(true)
                rotateIfNeeded()
                // A rotation that could not reopen the file leaves the logger
                // with nowhere to write, which is a failed open.
                return fileHandle != nil
            } catch {
                fileHandle = nil
                fileURL = nil
                setHasFile(false)
                return false
            }
        }
    }

    /// Waits for every line written so far to reach the file.
    ///
    /// The lines are written on a queue of their own, so a test that reads the
    /// file and the app on its way out both have to wait for it. It is a `sync`
    /// on the serial queue, which is a barrier: everything queued before it has
    /// run when it returns.
    public func flush() {
        queue.sync {}
    }

    /// Whether a file is open, for a caller deciding to build a line.
    private func setHasFile(_ open: Bool) {
        lock.lock()
        hasFile = open
        lock.unlock()
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
    ///
    /// The work is split by what belongs to which moment: the timestamp, the
    /// redaction of the fields and the decision whether the line is written at
    /// all are taken on the caller, because they describe the instant the line
    /// is about; the JSON and the file wait on the writer's queue. A caller that
    /// blocks on a rotation is a caller that drops a frame.
    public func write(_ level: LogLevel, _ event: String, _ fields: [String: LogValue] = [:]) {
        lock.lock()
        let allowed = level >= minimumLevel && hasFile
        lock.unlock()
        guard allowed else { return }

        var redacted: [String: LogValue] = [:]
        redacted.reserveCapacity(fields.count)
        for (key, value) in fields {
            if case .string(let text) = value {
                redacted[key] = .string(redact(text))
            } else {
                redacted[key] = value
            }
        }
        let line = Line(
            timestamp: Date().formatted(Self.timestamp),
            level: level,
            event: event,
            fields: redacted
        )
        queue.async { self.append(line) }
    }

    /// One line, waiting for the writer.
    private struct Line: Sendable {
        let timestamp: String
        let level: LogLevel
        let event: String
        let fields: [String: LogValue]
    }

    /// Serialises and writes one line. Runs on `queue`.
    private func append(_ line: Line) {
        var payload: [String: Any] = [
            "ts": line.timestamp,
            "level": line.level.rawValue,
            "event": line.event,
        ]
        for (key, value) in line.fields {
            payload[key] = value.jsonObject
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        var data = encoded
        data.append(0x0A)
        guard let handle = fileHandle else { return }
        if writtenBytes + data.count > limitBytes {
            rotate()
            guard fileHandle != nil else { return }
            fileHandle?.write(data)
            writtenBytes += data.count
            return
        }
        handle.write(data)
        writtenBytes += data.count
    }

    /// Whether the file on disk is larger than the limit, and the rotation that
    /// follows.
    private func rotateIfNeeded() {
        guard let fileURL else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        writtenBytes = size
        guard size > limitBytes else { return }
        rotate()
    }

    /// Keeps the newest whole lines and replaces the file with them.
    ///
    /// Only the tail is read: the file that is being rotated is the one that
    /// just grew to the limit, and none of the part that is dropped is needed.
    /// The replacement is written through ``SecureFile``, so the rotated file
    /// is still `0600`.
    private func rotate() {
        guard let fileURL, let handle = fileHandle else { return }
        let keep = min(retainBytes, max(0, writtenBytes))
        do {
            try handle.close()
            var tail = Data()
            if keep > 0 {
                let reader = try FileHandle(forReadingFrom: fileURL)
                defer { try? reader.close() }
                try reader.seek(toOffset: UInt64(max(0, writtenBytes - keep)))
                tail = try reader.readToEnd() ?? Data()
            }
            // The first line is the one the cut landed in the middle of.
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            let kept = tail.subdata(in: start..<tail.endIndex)
            try SecureFile.write(kept, to: fileURL)
            let reopened = try FileHandle(forWritingTo: fileURL)
            _ = try reopened.seekToEnd()
            fileHandle = reopened
            writtenBytes = kept.count
        } catch {
            // A log that cannot rotate is still a log: reopen it and keep
            // writing, so the failure does not silence every later line.
            if let reopened = try? FileHandle(forWritingTo: fileURL) {
                _ = try? reopened.seekToEnd()
                fileHandle = reopened
            } else {
                fileHandle = nil
                self.fileURL = nil
                setHasFile(false)
            }
        }
    }
}
