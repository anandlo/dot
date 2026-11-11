import Foundation
import XCTest

@testable import DotCore

/// What the files Dot keeps for itself are readable by.
///
/// The configuration names every endpoint the app talks to, the history holds
/// what was dictated and the log names the apps it was dictated into. A file
/// created with the default umask is `0644`, which is every account on the Mac.
final class SecureFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-secure-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAWrittenFileIsReadableOnlyByItsOwner() throws {
        let url = directory.appendingPathComponent("config.json")
        try SecureFile.write(Data("{}".utf8), to: url)

        XCTAssertEqual(SecureFile.permissions(of: url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}")
    }

    func testTheFolderIsWritableOnlyByItsOwner() throws {
        let url = directory.appendingPathComponent("config.json")
        try SecureFile.write(Data("{}".utf8), to: url)

        XCTAssertEqual(
            SecureFile.permissions(of: directory),
            0o700,
            "the folder holds the transcripts and the endpoints"
        )
    }

    func testAFileThatIsReplacedIsStillRestrictedAndHoldsTheNewBytes() throws {
        let url = directory.appendingPathComponent("history.json")
        try SecureFile.write(Data("old".utf8), to: url)
        try SecureFile.write(Data("new".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertEqual(SecureFile.permissions(of: url), 0o600)
    }

    func testNoTemporaryFileIsLeftBehind() throws {
        let url = directory.appendingPathComponent("config.json")
        try SecureFile.write(Data("{}".utf8), to: url)
        try SecureFile.write(Data("{\"a\":1}".utf8), to: url)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["config.json"], "a temporary file survived the replace")
    }

    func testAFileWrittenByAnOlderBuildIsRestrictedWhenItIsRead() throws {
        // A file the previous build wrote, with the permissions a plain write
        // gives it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        try Data(#"[{"text":"the quarterly numbers"}]"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
        XCTAssertEqual(SecureFile.permissions(of: url), 0o644)

        _ = HistoryStore.loadEntries(from: url)

        XCTAssertEqual(
            SecureFile.permissions(of: url),
            0o600,
            "reading the transcripts must close them to other accounts"
        )
    }

    func testTheConfigurationAndTheHistoryAreBothRestricted() throws {
        let configURL = directory.appendingPathComponent("config.json")
        try DotConfig.default.save(to: configURL)
        XCTAssertEqual(SecureFile.permissions(of: configURL), 0o600)

        let historyURL = directory.appendingPathComponent("history.json")
        HistoryStore.saveEntries([HistoryStore.Entry(text: "hello")], to: historyURL)
        XCTAssertEqual(SecureFile.permissions(of: historyURL), 0o600)
    }
}
