import Foundation
import XCTest

@testable import DotCore

/// Arguments are checked against the schema before any tool sees them.
///
/// A language model writes JSON, and JSON can hold anything. These tests pin
/// the checks that a tool may rely on: every field present, nothing extra, the
/// right type, inside the declared range.
final class ConnectorArgumentTests: XCTestCase {
    private let schema = ToolSchema([
        .init(name: "title", description: "A title.", field: .string(maxLength: 5)),
        .init(name: "when", description: "A window.", field: .choice(["today", "week"])),
        .init(name: "count", description: "A count.", field: .integer(1...10), isRequired: false),
        .init(name: "flag", description: "A flag.", field: .boolean, isRequired: false),
        .init(name: "tags", description: "Tags.", field: .strings(maxItems: 2, maxLength: 4), isRequired: false),
    ])

    private func validate(_ arguments: [String: JSONValue]) throws -> ValidatedArguments {
        try ArgumentValidator.validate(.object(arguments), against: schema)
    }

    func testAValidObjectIsAccepted() throws {
        let checked = try validate([
            "title": .string("hello"),
            "when": .string("today"),
            "count": .number(3),
            "flag": .bool(true),
            "tags": .array([.string("a"), .string("bb")]),
        ])
        XCTAssertEqual(checked.string("title"), "hello")
        XCTAssertEqual(checked.int("count"), 3)
        XCTAssertEqual(checked.bool("flag"), true)
        XCTAssertEqual(checked.strings("tags"), ["a", "bb"])
    }

    func testAMissingRequiredFieldIsRefused() {
        XCTAssertThrowsError(try validate(["title": .string("hello")])) { error in
            XCTAssertEqual(error as? ArgumentError, .missingField("when"))
        }
    }

    func testAnUnknownFieldIsRefused() {
        XCTAssertThrowsError(try validate([
            "title": .string("hello"),
            "when": .string("today"),
            "shell": .string("rm -rf /"),
        ])) { error in
            XCTAssertEqual(error as? ArgumentError, .unknownField("shell"))
        }
    }

    func testTheArgumentsMustBeAnObject() {
        XCTAssertThrowsError(try ArgumentValidator.validate(.array([]), against: schema)) { error in
            XCTAssertEqual(
                error as? ArgumentError,
                .wrongType(field: "arguments", expected: "JSON object")
            )
        }
    }

    func testAStringOfTheWrongTypeIsRefused() {
        XCTAssertThrowsError(try validate(["title": .number(1), "when": .string("today")])) { error in
            XCTAssertEqual(error as? ArgumentError, .wrongType(field: "title", expected: "string"))
        }
    }

    func testAStringOverItsLimitIsRefused() {
        XCTAssertThrowsError(try validate(["title": .string("toolong"), "when": .string("today")])) { error in
            XCTAssertEqual(error as? ArgumentError, .tooLong(field: "title", limit: 5))
        }
    }

    func testAValueOutsideItsChoiceIsRefusedWithoutEchoingIt() {
        XCTAssertThrowsError(try validate(["title": .string("ok"), "when": .string("someday")])) { error in
            let failure = error as? ArgumentError
            XCTAssertEqual(failure, .notAChoice(field: "when", allowed: ["today", "week"]))
            XCTAssertFalse(failure?.message.contains("someday") == true)
        }
    }

    func testAnIntegerOutsideItsRangeIsRefused() {
        XCTAssertThrowsError(try validate([
            "title": .string("ok"),
            "when": .string("today"),
            "count": .number(11),
        ])) { error in
            XCTAssertEqual(
                error as? ArgumentError,
                .outOfRange(field: "count", expected: "between 1 and 10")
            )
        }
    }

    func testAFractionIsNotAWholeNumber() {
        XCTAssertThrowsError(try validate([
            "title": .string("ok"),
            "when": .string("today"),
            "count": .number(1.5),
        ])) { error in
            XCTAssertEqual(error as? ArgumentError, .wrongType(field: "count", expected: "whole number"))
        }
    }

    func testAnEmptyStringIsRefused() {
        XCTAssertThrowsError(try validate(["title": .string("   "), "when": .string("today")])) { error in
            XCTAssertEqual(error as? ArgumentError, .empty(field: "title"))
        }
    }

    func testAControlCharacterIsRefusedButANewlineIsAllowed() throws {
        XCTAssertThrowsError(try validate([
            "title": .string("a\u{0}b"),
            "when": .string("today"),
        ])) { error in
            XCTAssertEqual(error as? ArgumentError, .unsupportedCharacter(field: "title"))
        }
        let checked = try validate([
            "title": .string("a\nb"),
            "when": .string("today"),
        ])
        XCTAssertEqual(checked.string("title"), "a\nb")
    }

    func testAListOverItsLimitIsRefused() {
        XCTAssertThrowsError(try validate([
            "title": .string("ok"),
            "when": .string("today"),
            "tags": .array([.string("a"), .string("b"), .string("c")]),
        ])) { error in
            XCTAssertEqual(error as? ArgumentError, .tooMany(field: "tags", limit: 2))
        }
    }

    func testAnOptionalFieldMayBeAbsent() throws {
        let checked = try validate(["title": .string("ok"), "when": .string("week")])
        XCTAssertFalse(checked.has("count"))
    }

    func testTheSchemaShownToTheModelSaysNothingExtraIsAllowed() {
        let json = schema.json
        XCTAssertEqual(json["additionalProperties"], .bool(false))
        XCTAssertEqual(json["type"], .string("object"))
        var required: [String] = []
        if case .array(let items)? = json["required"] {
            required = items.compactMap(\.stringValue)
        }
        XCTAssertEqual(Set(required), ["title", "when"])
    }
}
