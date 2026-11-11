import Foundation
import XCTest

@testable import DotCore

/// The decision an update check makes from one GitHub Releases response.
///
/// `/releases/latest` excludes prereleases, and every Dot release is one while
/// the product is in beta: that endpoint answers 404, and the list endpoint is
/// the one that can name a build. These tests pin the rule, one status and body
/// at a time, without a network.
final class ReleaseLookupTests: XCTestCase {
    // MARK: - The latest endpoint

    func testALatestReleaseIsFoundWithoutAskingAnywhereElse() {
        let body = Data(#"{"tag_name": "v1.2.3-beta", "html_url": "https://example.test/r"}"#.utf8)

        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 200, body: body),
            .found(ReleaseLookup.Release(version: "1.2.3-beta", page: "https://example.test/r"))
        )
    }

    func testTheGitHub404AsksForTheList() {
        // GitHub's own 404 body, which names no release. Every Dot release is a
        // prerelease, so this is the answer the check gets today.
        let body = Data(#"{"message":"Not Found","documentation_url":"https://docs.github.com"}"#.utf8)

        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 404, body: body),
            .askList(.httpStatus(404))
        )
    }

    func testAnyOtherFailureAsksForTheList() {
        for status in [301, 403, 429, 500, 503] {
            XCTAssertEqual(
                ReleaseLookup.decide(.latest, status: status, body: Data("{}".utf8)),
                .askList(.httpStatus(status)),
                "a \(status) from the latest endpoint has to be answered by the list"
            )
        }
    }

    func testAnEmptyBodyAsksForTheList() {
        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 200, body: Data()),
            .askList(.emptyBody)
        )
        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 200, body: Data("\n \r\n".utf8)),
            .askList(.emptyBody),
            "a body with nothing in it is empty"
        )
    }

    func testABodyWithoutATagAsksForTheList() {
        // The request did not come back with a release: an object without a
        // tag, a list where an object was expected, and bytes that are not JSON.
        for body in [#"{"message":"Not Found"}"#, "[]", "not json", #"{"tag_name": "  "}"#] {
            XCTAssertEqual(
                ReleaseLookup.decide(.latest, status: 200, body: Data(body.utf8)),
                .askList(.noTag),
                "\(body) names no release"
            )
        }
    }

    func testANonSuccessStatusWinsOverAPlausibleBody() {
        // A 404 carries a JSON body of its own; the status is the answer, not
        // what the body happens to contain.
        let body = Data(#"{"tag_name": "v9.9.9"}"#.utf8)

        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 404, body: body),
            .askList(.httpStatus(404))
        )
    }

    // MARK: - The list endpoint

    func testTheListNamesItsFirstRelease() {
        let body = Data(
            #"[{"tag_name": "v1.3.0-beta", "html_url": "https://example.test/newest"}, {"tag_name": "v1.2.0-beta"}]"#.utf8
        )

        XCTAssertEqual(
            ReleaseLookup.decide(.list, status: 200, body: body),
            .found(
                ReleaseLookup.Release(version: "1.3.0-beta", page: "https://example.test/newest")
            )
        )
    }

    func testAnEmptyListIsUnavailable() {
        XCTAssertEqual(
            ReleaseLookup.decide(.list, status: 200, body: Data("[]".utf8)),
            .unavailable(.noRelease)
        )
    }

    func testTheListIsNeverAskedToAskTheList() {
        // There is nowhere else to go after the list endpoint, so every failure
        // it can report is final.
        XCTAssertEqual(
            ReleaseLookup.decide(.list, status: 404, body: Data("{}".utf8)),
            .unavailable(.httpStatus(404))
        )
        XCTAssertEqual(
            ReleaseLookup.decide(.list, status: 200, body: Data()),
            .unavailable(.emptyBody)
        )
        XCTAssertEqual(
            ReleaseLookup.decide(.list, status: 200, body: Data(#"{"tag_name": "v1.2.3"}"#.utf8)),
            .unavailable(.noTag),
            "an object where the list's array belongs names no release"
        )
    }

    func testAnObjectWhereAListBelongsIsNotRead() {
        // The two endpoints answer with different shapes, and reading the wrong
        // one as the other would be how a check silently reports the wrong build.
        let entry = Data(#"{"tag_name": "v1.2.3-beta"}"#.utf8)

        XCTAssertEqual(ReleaseLookup.decide(.latest, status: 200, body: entry).tag, "1.2.3-beta")
        XCTAssertEqual(ReleaseLookup.decide(.list, status: 200, body: entry), .unavailable(.noTag))
    }

    // MARK: - The tag

    func testTheVersionDropsTheLeadingVAndAnySpace() {
        for tag in ["v1.2.3", "V1.2.3", "  v1.2.3\n", "1.2.3"] {
            XCTAssertEqual(ReleaseLookup.normalized(tag), "1.2.3", "\(tag) is a version")
        }
        XCTAssertEqual(ReleaseLookup.normalized("v"), "", "a lone v names nothing")
        XCTAssertEqual(ReleaseLookup.normalized(" beta "), "beta")
    }

    func testTheReleaseNotesTravelWhenTheResponseCarriesThem() {
        let body = Data(#"{"tag_name": "v1.2.3", "body": "- the first line"}"#.utf8)

        XCTAssertEqual(
            ReleaseLookup.decide(.latest, status: 200, body: body),
            .found(ReleaseLookup.Release(version: "1.2.3", page: nil, notes: "- the first line"))
        )
    }
}

private extension ReleaseLookup.Decision {
    /// The version the decision found, for the assertions that only care about
    /// the tag.
    var tag: String? {
        if case .found(let release) = self { return release.version }
        return nil
    }
}
