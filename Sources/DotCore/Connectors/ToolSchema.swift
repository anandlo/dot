import Foundation

/// One parameter of a tool, and the only values it accepts.
///
/// The schema is the single source of truth for two things: the JSON schema the
/// model is shown, and the check every argument passes before a tool may run.
/// Writing both from one declaration is what keeps them from drifting apart,
/// which is how a tool ends up accepting a value its description forbade.
public struct ToolSchema: Sendable, Equatable {
    /// The type of a field and the range it accepts.
    public enum Field: Sendable, Equatable {
        /// A string with a maximum length, in characters.
        case string(maxLength: Int = 400)
        /// A string from a fixed set.
        case choice([String])
        /// A whole number in a closed range.
        case integer(ClosedRange<Int>)
        /// A number in a closed range.
        case number(ClosedRange<Double>)
        /// A boolean.
        case boolean
        /// A list of strings, with a maximum count and a maximum length each.
        case strings(maxItems: Int = 8, maxLength: Int = 200)

        /// The JSON spelling of the field.
        public var json: JSONValue {
            switch self {
            case .string(let maxLength):
                .object(["type": .string("string"), "maxLength": .number(Double(maxLength))])
            case .choice(let values):
                .object(["type": .string("string"), "enum": .array(values.map { .string($0) })])
            case .integer(let range):
                .object([
                    "type": .string("integer"),
                    "minimum": .number(Double(range.lowerBound)),
                    "maximum": .number(Double(range.upperBound)),
                ])
            case .number(let range):
                .object([
                    "type": .string("number"),
                    "minimum": .number(range.lowerBound),
                    "maximum": .number(range.upperBound),
                ])
            case .boolean:
                .object(["type": .string("boolean")])
            case .strings(let maxItems, let maxLength):
                .object([
                    "type": .string("array"),
                    "maxItems": .number(Double(maxItems)),
                    "items": .object([
                        "type": .string("string"),
                        "maxLength": .number(Double(maxLength)),
                    ]),
                ])
            }
        }
    }

    /// One declared parameter.
    public struct Property: Sendable, Equatable {
        /// The name the model uses.
        public let name: String
        /// The sentence the model reads.
        public let description: String
        /// The values it accepts.
        public let field: Field
        /// Whether a call without it is rejected.
        public let isRequired: Bool

        /// Creates a property.
        public init(name: String, description: String, field: Field, isRequired: Bool = true) {
            self.name = name
            self.description = description
            self.field = field
            self.isRequired = isRequired
        }
    }

    /// The declared parameters, in the order the model reads them.
    public let properties: [Property]

    /// Creates a schema.
    public init(_ properties: [Property]) {
        self.properties = properties
    }

    /// The names of every declared parameter.
    public var names: Set<String> {
        Set(properties.map(\.name))
    }

    /// The property with that name, when one is declared.
    public func property(_ name: String) -> Property? {
        properties.first { $0.name == name }
    }

    /// The JSON schema shown to the model.
    ///
    /// `additionalProperties` is false so a model that invents a field is told
    /// so by the schema rather than by a failure after the side effect.
    public var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        for property in properties {
            fields[property.name] = .object([
                "description": .string(property.description),
                "type": property.field.json,
            ])
        }
        let required = properties.filter(\.isRequired).map { JSONValue.string($0.name) }
        return .object([
            "type": .string("object"),
            "properties": .object(fields),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ])
    }
}
