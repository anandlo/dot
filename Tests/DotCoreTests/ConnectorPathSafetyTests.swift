import Foundation
import XCTest

@testable import DotCore

/// Which paths a file tool may touch.
///
/// The Files connector is the only one that can lose something a person cannot
/// undo, and the model chooses the path. Each test here is a way a path could
/// escape the home folder: a symlink, a relative path, another account, a
/// system location, the home folder itself, an application bundle.
final class ConnectorPathSafetyTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var safety: PathSafety!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-path-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        safety = PathSafety(home: home, protected: [])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAPathInsideHomeIsAllowedForEveryIntent() throws {
        let file = home.appendingPathComponent("notes.txt")
        for intent in PathSafety.Intent.allCases {
            XCTAssertNoThrow(try safety.check(file.path, intent: intent), "\(intent) refused a home path")
        }
    }

    func testAHomePathIsCanonicalised() throws {
        let messy = home.path + "/sub/../notes.txt"
        let checked = try safety.check(messy, intent: .write)
        XCTAssertEqual(checked.path, safety.home.path + "/notes.txt")
    }

    func testTildeIsExpandedToTheHomeFolder() throws {
        let checked = try safety.check("~/notes.txt", intent: .write)
        XCTAssertEqual(checked.path, safety.home.path + "/notes.txt")
    }

    func testAnotherAccountsTildeIsNotAbsolute() {
        XCTAssertThrowsError(try safety.check("~someone/notes.txt", intent: .read)) { error in
            XCTAssertEqual(error as? PathSafety.Failure, .notAbsolute)
        }
    }

    func testARelativePathIsRefused() {
        XCTAssertThrowsError(try safety.check("notes.txt", intent: .read)) { error in
            XCTAssertEqual(error as? PathSafety.Failure, .notAbsolute)
        }
    }

    func testAnEmptyPathIsRefused() {
        XCTAssertThrowsError(try safety.check("   ", intent: .read)) { error in
            XCTAssertEqual(error as? PathSafety.Failure, .empty)
        }
    }

    func testAPathWithANullByteIsRefused() {
        XCTAssertThrowsError(try safety.check("/tmp/a\0b", intent: .read)) { error in
            XCTAssertEqual(error as? PathSafety.Failure, .malformed)
        }
    }

    func testSystemLocationsAreRefusedForWriting() {
        for path in ["/System/Library/CoreServices", "/Library/Preferences", "/usr/bin", "/Applications/Slack.app"] {
            XCTAssertThrowsError(try safety.check(path, intent: .write)) { error in
                guard case .systemLocation = error as? PathSafety.Failure else {
                    return XCTFail("Expected a system refusal for \(path), got \(error)")
                }
            }
        }
    }

    func testAnotherUsersHomeIsRefused() {
        XCTAssertThrowsError(try safety.check("/Users/not-this-account/Documents/a.txt", intent: .read)) { error in
            guard case .anotherUser = error as? PathSafety.Failure else {
                return XCTFail("Expected another-user refusal, got \(error)")
            }
        }
    }

    func testTheHomeFolderItselfCannotBeTrashedOrMoved() {
        for intent in [PathSafety.Intent.trash, .moveSource] {
            XCTAssertThrowsError(try safety.check(home.path, intent: intent)) { error in
                XCTAssertEqual(error as? PathSafety.Failure, .isHome)
            }
        }
    }

    func testAWriteOrMoveOutsideHomeIsRefused() {
        let outside = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/a.txt").path
        for intent in [PathSafety.Intent.write, .moveSource, .moveDestination, .trash] {
            XCTAssertThrowsError(try safety.check(outside, intent: intent)) { error in
                XCTAssertEqual(error as? PathSafety.Failure, .outsideHome(outside), "\(intent)")
            }
        }
    }

    func testAReadOutsideHomeIsAllowed() {
        // Reading elsewhere is how a search result in an external volume can be
        // opened; only writing is confined.
        XCTAssertNoThrow(try safety.check("/Volumes/Backup/report.pdf", intent: .read))
    }

    func testAWriteToAnotherVolumeIsRefused() {
        XCTAssertThrowsError(try safety.check("/Volumes/Backup/report.pdf", intent: .write)) { error in
            guard case .outsideHome = error as? PathSafety.Failure else {
                return XCTFail("Expected an outside-home refusal, got \(error)")
            }
        }
    }

    func testASymlinkCannotCarryAWriteOutOfHome() throws {
        let link = home.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System"))
        XCTAssertThrowsError(try safety.check(link.appendingPathComponent("a.txt").path, intent: .write)) { error in
            guard case .systemLocation = error as? PathSafety.Failure else {
                return XCTFail("A resolved symlink must be refused, got \(error)")
            }
        }
    }

    func testAnApplicationBundleCannotBeMovedOrTrashed() throws {
        let app = home.appendingPathComponent("Sneaky.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        for intent in [PathSafety.Intent.moveSource, .trash] {
            XCTAssertThrowsError(try safety.check(app.path, intent: intent)) { error in
                guard case .applicationBundle = error as? PathSafety.Failure else {
                    return XCTFail("Expected an application refusal, got \(error)")
                }
            }
        }
    }

    func testAProtectedPathIsRefused() throws {
        let protected = home.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let guarded = PathSafety(home: home, protected: [protected])
        XCTAssertThrowsError(try guarded.check(protected.appendingPathComponent("a.txt").path, intent: .read)) { error in
            guard case .protected = error as? PathSafety.Failure else {
                return XCTFail("Expected a protected refusal, got \(error)")
            }
        }
    }

    func testTheDefaultGuardProtectsTheRunningBundle() throws {
        let guardDefault = PathSafety(home: home)
        XCTAssertFalse(guardDefault.protected.isEmpty)
    }
}
