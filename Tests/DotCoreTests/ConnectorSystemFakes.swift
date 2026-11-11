import Foundation

@testable import DotCore

/// A file search that returns prepared hits.
final class FakeFileSearching: FileSearching, @unchecked Sendable {
    private let hits: [FileHit]
    private(set) var queries: [FileQuery] = []

    init(hits: [FileHit]) {
        self.hits = hits
    }

    func search(_ query: FileQuery) async throws -> [FileHit] {
        queries.append(query)
        return Array(hits.prefix(query.limit))
    }
}

/// File operations that record instead of touching disk.
final class FakeFileOperating: FileOperating, @unchecked Sendable {
    let recorder = FileOperationRecorder()
    private let existing: Set<String>

    init(existing: Set<String>) {
        self.existing = existing
    }

    func open(_ url: URL) async throws {
        await recorder.record("open:\(url.path)")
    }

    func reveal(_ url: URL) async throws {
        await recorder.record("reveal:\(url.path)")
    }

    func move(_ source: URL, to destination: URL) async throws -> URL {
        await recorder.record("move:\(source.path)->\(destination.path)")
        return destination
    }

    func trash(_ url: URL) async throws -> URL {
        await recorder.record("trash:\(url.path)")
        return url
    }

    func exists(_ url: URL) async -> Bool {
        existing.contains(url.path)
    }

    func size(of url: URL) async -> Int64? {
        42
    }
}

/// What a fake file layer was asked to do.
actor FileOperationRecorder {
    private(set) var operations: [String] = []

    func record(_ operation: String) {
        operations.append(operation)
    }

    var count: Int { operations.count }
}

/// An app launcher that records instead of launching.
final class FakeAppLauncher: AppLaunching, @unchecked Sendable {
    let recorder = AppRecorder()

    func openApp(named name: String) async throws {
        await recorder.record("app:\(name)")
    }

    func open(_ url: URL) async throws {
        await recorder.record("url:\(url.absoluteString)")
    }

    func runningApplications() async -> [RunningApp] {
        [
            RunningApp(name: "Safari", bundleID: "com.apple.Safari", isActive: true),
            RunningApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", isActive: false),
        ]
    }
}

/// What a fake app launcher was asked to open.
actor AppRecorder {
    private(set) var opened: [String] = []

    func record(_ value: String) {
        opened.append(value)
    }
}

/// A shortcuts runner a test can fill.
actor FakeShortcutRunner: ShortcutRunning {
    private(set) var library: [String]
    private(set) var runs: [(name: String, input: String?)] = []
    private var failure: StoreError?

    init(library: [String] = ["Morning", "Focus", "Speak Text"]) {
        self.library = library
    }

    func setFailure(_ error: StoreError?) {
        failure = error
    }

    func list() async throws -> [String] {
        if let failure { throw failure }
        return library
    }

    func run(name: String, input: String?) async throws -> String {
        if let failure { throw failure }
        runs.append((name, input))
        return "ran \(name)"
    }
}
