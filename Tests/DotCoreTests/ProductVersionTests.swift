import XCTest

@testable import DotCore

/// `VERSION` at the package root is the only place a version is written down.
///
/// `scripts/build.sh` reads it into `CFBundleShortVersionString` and
/// `Sources/Dot/ProductVersion.swift` reads it back out, so the About window,
/// the update check and the log cannot disagree with the bundle. This guard
/// keeps it that way: a second copy of the string is how one of them ends up
/// reporting a version the build does not have.
final class ProductVersionTests: XCTestCase {
    /// The package root.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The version the package declares.
    private static func declaredVersion() throws -> String {
        let text = try String(
            contentsOf: root.appendingPathComponent("VERSION"),
            encoding: .utf8
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheVersionFileHoldsOneVersion() throws {
        let version = try Self.declaredVersion()
        XCTAssertFalse(version.isEmpty)
        XCTAssertFalse(version.contains("\n"), "VERSION holds one line")
        XCTAssertNotNil(
            version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression),
            "\(version) is not a marketing version"
        )
    }

    /// No Swift source and no script may spell the version out: a copy would
    /// stop moving the day the file changes.
    func testTheVersionIsWrittenDownOnlyInTheVersionFile() throws {
        let version = try Self.declaredVersion()
        var offenders: [String] = []
        for file in Self.swiftFiles() + Self.scriptFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(version) {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "the version is hardcoded outside VERSION")
    }

    /// The bundle carries the version, which is what the app reports at run time.
    func testTheBuildWritesTheVersionIntoTheBundle() throws {
        let build = try String(
            contentsOf: Self.root.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            build.contains("<key>CFBundleShortVersionString</key>\n\t<string>$MARKETING_VERSION</string>"),
            "the bundle version is not injected from VERSION"
        )
        let config = try String(
            contentsOf: Self.root.appendingPathComponent("scripts/config.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("MARKETING_VERSION"), "config.sh does not read VERSION")
    }

    /// The answer is either what the bundle declares or the documented
    /// fallback, never an empty string the About window would print as a blank.
    func testTheReportedVersionIsNeverEmpty() {
        XCTAssertFalse(ProductVersion.unknown.isEmpty)
        XCTAssertFalse(ProductVersion.current.isEmpty)
        XCTAssertEqual(
            ProductVersion.current,
            ProductVersion.current.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - The tree

    private static func swiftFiles() -> [URL] {
        files(in: root.appendingPathComponent("Sources", isDirectory: true), suffix: ".swift")
            + files(in: root.appendingPathComponent("Tests", isDirectory: true), suffix: ".swift")
    }

    private static func scriptFiles() -> [URL] {
        files(in: root.appendingPathComponent("scripts", isDirectory: true), suffix: ".sh")
    }

    private static func files(in directory: URL, suffix: String) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var result: [URL] = []
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                result.append(contentsOf: files(in: child, suffix: suffix))
            } else if child.lastPathComponent.hasSuffix(suffix) {
                result.append(child)
            }
        }
        return result
    }
}
