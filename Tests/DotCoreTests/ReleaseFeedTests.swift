import Foundation
import XCTest

@testable import DotCore

/// The fallback the update check makes over the wire.
///
/// The two endpoints are stubbed on a local port, so the test sees the requests
/// the check actually sends: `/releases/latest` first, then
/// `/releases?per_page=1` — the same pair, in the same order, as
/// `scripts/install-remote.sh`. A 404 from the first is expected rather than a
/// failure, because GitHub leaves prereleases out of it.
final class ReleaseFeedTests: XCTestCase {
    func testA404FromTheLatestEndpointFallsBackToTheList() async throws {
        let server = try StubServer(responses: [
            .init(status: 404, json: #"{"message":"Not Found"}"#),
            .init(
                status: 200,
                json: #"[{"tag_name":"v1.2.3-beta","html_url":"https://example.test/tag"}]"#
            ),
        ])
        let feed = try makeFeed(server)

        let release = try await feed.newest()

        XCTAssertEqual(release.version, "1.2.3-beta")
        XCTAssertEqual(release.page, "https://example.test/tag")
        XCTAssertEqual(
            server.requests.map(\.path),
            ["/repos/anandlo/dot/releases/latest", "/repos/anandlo/dot/releases"],
            "the check has to ask the latest endpoint and then the list"
        )
        XCTAssertEqual(server.requests.last?.query, "per_page=1", "the list is read newest first")
        XCTAssertEqual(server.requests.last?.header("Accept"), "application/vnd.github.v3+json")
        XCTAssertEqual(server.requests.last?.header("User-Agent"), "Dot-App-Updater")
    }

    func testAnAnswerFromTheLatestEndpointIsNotAskedTwice() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"tag_name":"v1.2.3","html_url":"https://example.test/tag"}"#),
        ])
        let feed = try makeFeed(server)

        let release = try await feed.newest()

        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(server.requests.count, 1, "a release was found, so nothing else is read")
        XCTAssertEqual(server.requests.first?.path, "/repos/anandlo/dot/releases/latest")
    }

    func testTheListIsUsedWhenTheLatestEndpointIsEmpty() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: ""),
            .init(status: 200, json: #"[{"tag_name":"v1.2.3-beta"}]"#),
        ])
        let feed = try makeFeed(server)

        let release = try await feed.newest()

        XCTAssertEqual(release.version, "1.2.3-beta")
        XCTAssertEqual(server.requests.count, 2)
    }

    func testTwoFailuresThrowTheReasonTheListGave() async throws {
        let server = try StubServer(responses: [
            .init(status: 500, json: #"{"message":"boom"}"#),
            .init(status: 503, json: #"{"message":"later"}"#),
        ])
        let feed = try makeFeed(server)

        do {
            _ = try await feed.newest()
            XCTFail("neither endpoint named a release, so the check cannot succeed")
        } catch {
            XCTAssertEqual(error as? ReleaseFeedError, ReleaseFeedError(reason: .httpStatus(503)))
        }
        XCTAssertEqual(server.requests.count, 2, "both endpoints were asked before giving up")
    }

    func testAnEmptyListThrowsThatNoReleaseExists() async throws {
        let server = try StubServer(responses: [
            .init(status: 404, json: #"{"message":"Not Found"}"#),
            .init(status: 200, json: "[]"),
        ])
        let feed = try makeFeed(server)

        do {
            _ = try await feed.newest()
            XCTFail("an empty list names no release")
        } catch {
            XCTAssertEqual(error as? ReleaseFeedError, ReleaseFeedError(reason: .noRelease))
        }
    }

    /// A feed pointed at the stub, on the same paths the app uses.
    private func makeFeed(_ server: StubServer) throws -> ReleaseFeed {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/repos/anandlo/dot/releases"))
        return ReleaseFeed(
            latest: root.appendingPathComponent("latest"),
            list: URL(string: "http://127.0.0.1:\(server.port)/repos/anandlo/dot/releases?per_page=1")!
        )
    }
}
