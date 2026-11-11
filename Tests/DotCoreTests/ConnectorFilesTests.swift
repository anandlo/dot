import Foundation
import XCTest

@testable import DotCore

/// Files: the path check runs before the file layer, every time.
///
/// The fakes make it visible when a refused path still reached an operation.
/// "Zero operations" is the assertion that matters: a model that asks to trash
/// `/System` must not get as far as a `FileManager` call.
final class ConnectorFilesTests: XCTestCase {
    private var root: URL!
    private var safety: PathSafety!
    private var file: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-files-tests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        safety = PathSafety(home: home, protected: [])
        file = safety.home.appendingPathComponent("report.pdf")
        try Data("pdf".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func connector(operations: FakeFileOperating, hits: [FileHit] = []) -> FilesConnector {
        FilesConnector(safety: safety, searcher: FakeFileSearching(hits: hits), files: operations)
    }

    func testASearchResultOutsideHomeIsDropped() async throws {
        let operations = FakeFileOperating(existing: [])
        let outside = FileHit(path: "/System/Library/CoreServices/x", name: "x", modified: nil, sizeBytes: nil, isFolder: false)
        let inside = FileHit(path: file.path, name: "report.pdf", modified: Date(), sizeBytes: 3, isFolder: false)
        let files = connector(operations: operations, hits: [outside, inside])
        let call = try validatedCall(files, name: "files_search", arguments: ["query": .string("report")])
        let outcome = await files.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("report.pdf"))
        XCTAssertFalse(outcome.text.contains("CoreServices"))
    }

    func testTrashingOutsideHomeNeverReachesTheFileLayer() async throws {
        let operations = FakeFileOperating(existing: [])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_trash", arguments: ["path": .string("/System/Library/CoreServices")])
        let outcome = await files.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("system location"))
        let count = await operations.recorder.count
        XCTAssertEqual(count, 0, "A refused path must not reach trashItem")
    }

    func testTrashingInsideHomeCallsTrashOnce() async throws {
        let operations = FakeFileOperating(existing: [file.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_trash", arguments: ["path": .string("~/report.pdf")])
        let outcome = await files.invoke(call)
        XCTAssertFalse(outcome.isError)
        let recorded = await operations.recorder.operations
        XCTAssertEqual(recorded, ["trash:\(file.path)"])
    }

    func testMovingOntoAnExistingNameIsRefused() async throws {
        let destination = safety.home.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existingCopy = destination.appendingPathComponent("report.pdf")
        try Data().write(to: existingCopy)
        let operations = FakeFileOperating(existing: [file.path, destination.path, existingCopy.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_move", arguments: [
            "path": .string(file.path),
            "folder": .string(destination.path),
        ])
        let outcome = await files.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("already"))
        let count = await operations.recorder.count
        XCTAssertEqual(count, 0)
    }

    func testMovingInsideHomeWorks() async throws {
        let destination = safety.home.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let operations = FakeFileOperating(existing: [file.path, destination.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_move", arguments: [
            "path": .string(file.path),
            "folder": .string(destination.path),
        ])
        let outcome = await files.invoke(call)
        XCTAssertFalse(outcome.isError)
        let recorded = await operations.recorder.operations
        XCTAssertEqual(
            recorded,
            ["move:\(file.path)->\(destination.path)/report.pdf"]
        )
    }

    func testRenamingRejectsASlash() async throws {
        let operations = FakeFileOperating(existing: [file.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_rename", arguments: [
            "path": .string(file.path),
            "name": .string("sub/report.pdf"),
        ])
        let outcome = await files.invoke(call)
        XCTAssertTrue(outcome.isError)
        let count = await operations.recorder.count
        XCTAssertEqual(count, 0)
    }

    func testRenamingInsideHomeWorks() async throws {
        let operations = FakeFileOperating(existing: [file.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_rename", arguments: [
            "path": .string(file.path),
            "name": .string("2026 report.pdf"),
        ])
        let outcome = await files.invoke(call)
        XCTAssertFalse(outcome.isError)
        let recorded = await operations.recorder.operations
        XCTAssertEqual(recorded, ["move:\(file.path)->\(safety.home.path)/2026 report.pdf"])
    }

    func testOpeningASystemFileIsRefused() async throws {
        let operations = FakeFileOperating(existing: [])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_open", arguments: ["path": .string("/System/Applications/Calculator.app")])
        let outcome = await files.invoke(call)
        XCTAssertTrue(outcome.isError)
        let count = await operations.recorder.count
        XCTAssertEqual(count, 0)
    }

    func testRevealingInsideHomeWorks() async throws {
        let operations = FakeFileOperating(existing: [file.path])
        let files = connector(operations: operations)
        let call = try validatedCall(files, name: "files_reveal", arguments: ["path": .string(file.path)])
        let outcome = await files.invoke(call)
        XCTAssertFalse(outcome.isError)
        let recorded = await operations.recorder.operations
        XCTAssertEqual(recorded, ["reveal:\(file.path)"])
    }

    func testTheToolRisksAreDeclared() {
        let files = connector(operations: FakeFileOperating(existing: []))
        XCTAssertEqual(files.tool(named: "files_search")?.risk, .read)
        XCTAssertEqual(files.tool(named: "files_reveal")?.risk, .read)
        XCTAssertEqual(files.tool(named: "files_move")?.risk, .write)
        XCTAssertEqual(files.tool(named: "files_rename")?.risk, .write)
        XCTAssertEqual(files.tool(named: "files_trash")?.risk, .destructive)
        XCTAssertEqual(files.tool(named: "files_open")?.risk, .external)
    }

    func testFileToolsNeedNoPermission() async {
        let files = connector(operations: FakeFileOperating(existing: []))
        let permission = await files.permission()
        XCTAssertTrue(permission.allowsTools)
        XCTAssertEqual(permission.status, .granted)
    }
}
