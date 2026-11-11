import Foundation

/// Why a set of arguments was refused.
///
/// The messages are written for the model, not for a log: they name the field
/// and what it accepts. They never repeat the received value, because an
/// argument can be a person's name, an address or a message body, and an error
/// is often shown in the transcript.
public enum ArgumentError: Error, Equatable, Sendable {
    /// A key the schema does not declare.
    case unknownField(String)
    /// A required key that is absent.
    case missingField(String)
    /// A value of the wrong JSON type.
    case wrongType(field: String, expected: String)
    /// A number outside its declared range.
    case outOfRange(field: String, expected: String)
    /// A string outside its declared choice.
    case notAChoice(field: String, allowed: [String])
    /// A string longer than declared.
    case tooLong(field: String, limit: Int)
    /// A list with more entries than declared.
    case tooMany(field: String, limit: Int)
    /// A string that is empty, or only whitespace.
    case empty(field: String)
    /// A string holding a character that is not allowed.
    case unsupportedCharacter(field: String)

    /// The sentence the model reads.
    public var message: String {
        switch self {
        case .unknownField(let field):
            "The field '\(field)' is not accepted by this tool."
        case .missingField(let field):
            "The field '\(field)' is required."
        case .wrongType(let field, let expected):
            "The field '\(field)' must be a \(expected)."
        case .outOfRange(let field, let expected):
            "The field '\(field)' must be \(expected)."
        case .notAChoice(let field, let allowed):
            "The field '\(field)' must be one of: \(allowed.joined(separator: ", "))."
        case .tooLong(let field, let limit):
            "The field '\(field)' is longer than \(limit) characters."
        case .tooMany(let field, let limit):
            "The field '\(field)' may have at most \(limit) entries."
        case .empty(let field):
            "The field '\(field)' must not be empty."
        case .unsupportedCharacter(let field):
            "The field '\(field)' contains a control character."
        }
    }
}

/// Arguments that passed the schema, read through typed accessors.
///
/// A value that reached this type has already been checked against its
/// declared field, so the accessors never have to fail a second time. The
/// values are stored as they were validated, so a tool reads exactly what the
/// schema approved.
public struct ValidatedArguments: Sendable, Equatable {
    private let values: [String: JSONValue]

    /// Wraps checked values. Only ``ArgumentValidator`` calls this.
    init(values: [String: JSONValue]) {
        self.values = values
    }

    /// Every validated pair.
    public var all: [String: JSONValue] { values }

    /// A string field.
    public func string(_ name: String) -> String? {
        values[name]?.stringValue
    }

    /// A whole-number field.
    public func int(_ name: String) -> Int? {
        guard case .number(let number)? = values[name] else { return nil }
        guard number.rounded() == number else { return nil }
        guard number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    /// A number field.
    public func number(_ name: String) -> Double? {
        guard case .number(let number)? = values[name] else { return nil }
        return number
    }

    /// A boolean field.
    public func bool(_ name: String) -> Bool? {
        guard case .bool(let flag)? = values[name] else { return nil }
        return flag
    }

    /// A list-of-strings field.
    public func strings(_ name: String) -> [String]? {
        guard case .array(let items)? = values[name] else { return nil }
        return items.compactMap(\.stringValue)
    }

    /// Whether the field was supplied at all.
    public func has(_ name: String) -> Bool {
        values[name] != nil
    }
}

/// Checks model-supplied arguments against a tool's schema.
public enum ArgumentValidator {
    /// Validates every field and rejects anything undeclared.
    ///
    /// - Parameters:
    ///   - arguments: the arguments as they arrived.
    ///   - schema: the tool's declared fields.
    /// - Returns: the values, ready to read.
    /// - Throws: ``ArgumentError`` for the first field that fails.
    public static func validate(
        _ arguments: JSONValue,
        against schema: ToolSchema
    ) throws -> ValidatedArguments {
        guard let members = arguments.objectValue else {
            throw ArgumentError.wrongType(field: "arguments", expected: "JSON object")
        }
        let declared = schema.names
        if let unknown = members.keys.sorted().first(where: { !declared.contains($0) }) {
            throw ArgumentError.unknownField(unknown)
        }
        var checked: [String: JSONValue] = [:]
        for property in schema.properties {
            guard let value = members[property.name], value != .null else {
                if property.isRequired { throw ArgumentError.missingField(property.name) }
                continue
            }
            checked[property.name] = try check(value, for: property)
        }
        return ValidatedArguments(values: checked)
    }

    /// Checks one value against one declared field.
    private static func check(_ value: JSONValue, for property: ToolSchema.Property) throws -> JSONValue {
        switch property.field {
        case .string(let maxLength):
            let text = try string(value, field: property.name)
            guard text.count <= maxLength else {
                throw ArgumentError.tooLong(field: property.name, limit: maxLength)
            }
            return .string(text)
        case .choice(let allowed):
            let text = try string(value, field: property.name)
            guard allowed.contains(text) else {
                throw ArgumentError.notAChoice(field: property.name, allowed: allowed)
            }
            return .string(text)
        case .integer(let range):
            guard case .number(let number) = value, number.rounded() == number else {
                throw ArgumentError.wrongType(field: property.name, expected: "whole number")
            }
            guard Double(range.lowerBound) <= number, number <= Double(range.upperBound) else {
                throw ArgumentError.outOfRange(
                    field: property.name,
                    expected: "between \(range.lowerBound) and \(range.upperBound)"
                )
            }
            return value
        case .number(let range):
            guard case .number(let number) = value else {
                throw ArgumentError.wrongType(field: property.name, expected: "number")
            }
            guard range.contains(number) else {
                throw ArgumentError.outOfRange(
                    field: property.name,
                    expected: "between \(range.lowerBound) and \(range.upperBound)"
                )
            }
            return value
        case .boolean:
            guard case .bool = value else {
                throw ArgumentError.wrongType(field: property.name, expected: "boolean")
            }
            return value
        case .strings(let maxItems, let maxLength):
            guard case .array(let items) = value else {
                throw ArgumentError.wrongType(field: property.name, expected: "list of strings")
            }
            guard items.count <= maxItems else {
                throw ArgumentError.tooMany(field: property.name, limit: maxItems)
            }
            var checked: [JSONValue] = []
            for item in items {
                let text = try string(item, field: property.name)
                guard text.count <= maxLength else {
                    throw ArgumentError.tooLong(field: property.name, limit: maxLength)
                }
                checked.append(.string(text))
            }
            return .array(checked)
        }
    }

    /// Reads a field as a trimmed, non-empty, control-character-free string.
    private static func string(_ value: JSONValue, field: String) throws -> String {
        guard let raw = value.stringValue else {
            throw ArgumentError.wrongType(field: field, expected: "string")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ArgumentError.empty(field: field) }
        guard !text.unicodeScalars.contains(where: isForbiddenControl) else {
            throw ArgumentError.unsupportedCharacter(field: field)
        }
        return text
    }

    /// A character a tool may not carry. Tab and newline are allowed: a note or
    /// a message body can legitimately have both.
    private static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" || scalar == "\r" { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }
}
