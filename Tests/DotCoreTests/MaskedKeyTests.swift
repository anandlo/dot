import XCTest
@testable import DotCore

final class MaskedKeyTests: XCTestCase {
    func testNoKeyHasNoDescription() {
        XCTAssertNil(MaskedKey.describe(nil))
        XCTAssertNil(MaskedKey.describe(""))
        XCTAssertNil(MaskedKey.describe("   \n "))
    }

    func testALongKeyKeepsOnlyTheEnds() {
        let key = "sk-proj-abcdefghijklmnop-1234"
        let described = MaskedKey.describe(key)
        XCTAssertEqual(described, "sk-p…1234")
        // The middle must never survive.
        XCTAssertFalse(described?.contains("abcdefghij") ?? true)
    }

    func testAShortKeyIsHiddenEntirely() {
        // Anything shorter than the two windows plus a gap would be the key.
        for short in ["abc", "sk-1234", "0123456789abc"] {
            XCTAssertEqual(MaskedKey.describe(short), "••••", "short key \(short) must not be shown")
        }
    }

    func testExactlyTheMinimumLengthIsMasked() {
        let key = String(repeating: "a", count: MaskedKey.minimumLength)
        let described = MaskedKey.describe(key)
        XCTAssertEqual(described, "aaaa…aaaa")
        XCTAssertLessThan(described?.count ?? .max, key.count)
    }

    func testSurroundingWhitespaceIsIgnored() {
        let key = "  sk-proj-abcdefghijklmnop-1234  "
        XCTAssertEqual(MaskedKey.describe(key), "sk-p…1234")
    }
}
