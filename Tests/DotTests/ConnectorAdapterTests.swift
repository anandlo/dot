import DotCore
import XCTest

@testable import Dot

/// The app-layer adapters that have logic worth pinning.
///
/// EventKit, Contacts and AppleScript cannot run in CI without touching a real
/// account, and they are thin enough that the tests cover the two parts that
/// are pure: the Spotlight predicate and the file moves. The rest is exercised
/// by the protocols and the fakes in `DotCoreTests`.
final class ConnectorAdapterTests: XCTestCase {
    func testTheSpotlightPredicateUsesContainsNotLike() {
        let predicate = SpotlightFileSearch.predicate(for: FileQuery(text: "report"))
        let format = predicate.predicateFormat
        XCTAssertTrue(format.contains("CONTAINS[cd]"), format)
        XCTAssertFalse(format.contains("LIKE"), "A wildcard in a name must not change the query")
        XCTAssertTrue(format.contains("report"))
    }

    func testAWildcardInTheNameIsData() {
        let predicate = SpotlightFileSearch.predicate(for: FileQuery(text: "*"))
        XCTAssertFalse(predicate.predicateFormat.contains("LIKE"))
        XCTAssertTrue(predicate.predicateFormat.contains("\"*\""))
    }

    func testAKindBecomesAUniformType() {
        let folder = SpotlightFileSearch.predicate(for: FileQuery(text: "a", kind: .folder)).predicateFormat
        XCTAssertTrue(folder.contains("public.folder"), folder)
        let image = SpotlightFileSearch.predicate(for: FileQuery(text: "a", kind: .image)).predicateFormat
        XCTAssertTrue(image.contains("kMDItemContentTypeTree"), image)
        XCTAssertTrue(image.contains("public.image"), image)
    }

    func testAChangedWithinBecomesADateClause() {
        let predicate = SpotlightFileSearch.predicate(for: FileQuery(text: "a", modifiedWithinDays: 7))
        XCTAssertTrue(predicate.predicateFormat.contains("kMDItemFSContentChangeDate"))
    }

    func testAGeneralQueryHasNoKindOrDateClause() {
        let format = SpotlightFileSearch.predicate(for: FileQuery(text: "a")).predicateFormat
        XCTAssertFalse(format.contains("public."))
        XCTAssertFalse(format.contains("kMDItemFSContentChangeDate"))
    }

    func testMovingAFileWorksAndRefusesToOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-adapter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        let destination = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: source)
        let operations = FileSystemOperations()

        let moved = try await operations.move(source, to: destination)
        XCTAssertEqual(moved, destination)
        let destinationExists = await operations.exists(destination)
        let sourceExists = await operations.exists(source)
        let movedSize = await operations.size(of: destination)
        XCTAssertTrue(destinationExists)
        XCTAssertFalse(sourceExists)
        XCTAssertEqual(movedSize, 1)

        try Data("c".utf8).write(to: source)
        do {
            _ = try await operations.move(source, to: destination)
            XCTFail("A move onto an existing name must be refused")
        } catch let error as StoreError {
            XCTAssertTrue(error.message.contains("already"))
        }
        let sourceStillThere = await operations.exists(source)
        XCTAssertTrue(sourceStillThere, "The refused move must leave the source alone")
    }

    func testTheAppLauncherRefusesANameThatIsAPath() async {
        let launcher = WorkspaceLauncher()
        do {
            try await launcher.openApp(named: "/tmp/evil.app")
            XCTFail("A path is not an application name")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
    }

    func testRunningApplicationsHaveNames() async {
        let apps = await WorkspaceLauncher().runningApplications()
        for app in apps {
            XCTAssertFalse(app.name.isEmpty)
        }
    }
}
