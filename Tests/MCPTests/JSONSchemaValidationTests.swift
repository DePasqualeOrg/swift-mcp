import Foundation
import Testing

@testable import MCP

/// Tests for JSON Schema validation functionality.
///
/// These tests verify the DefaultJSONSchemaValidator implementation against
/// various JSON Schema 2020-12 features, following the test patterns from
/// the TypeScript and Python SDKs.
@Suite("JSON Schema Validation Tests")
struct JSONSchemaValidationTests {
    let validator = DefaultJSONSchemaValidator()

    // MARK: - String Schemas

    @Test("Validates basic string type")
    func basicString() throws {
        let schema: Value = ["type": "string"]

        // Valid
        try validator.validate(.string("hello"), against: schema)

        // Invalid - number instead of string
        #expect(throws: MCPError.self) {
            try validator.validate(.int(123), against: schema)
        }
    }

    @Test("Validates string with length constraints")
    func stringLengthConstraints() throws {
        let schema: Value = [
            "type": "string",
            "minLength": 3,
            "maxLength": 10,
        ]

        // Valid
        try validator.validate(.string("abc"), against: schema)
        try validator.validate(.string("abcdefghij"), against: schema)

        // Too short
        #expect(throws: MCPError.self) {
            try validator.validate(.string("ab"), against: schema)
        }

        // Too long
        #expect(throws: MCPError.self) {
            try validator.validate(.string("abcdefghijk"), against: schema)
        }
    }

    @Test("Validates string pattern")
    func stringPattern() throws {
        let schema: Value = [
            "type": "string",
            "pattern": "^[A-Z]{3}$",
        ]

        // Valid
        try validator.validate(.string("ABC"), against: schema)

        // Invalid - lowercase
        #expect(throws: MCPError.self) {
            try validator.validate(.string("abc"), against: schema)
        }

        // Invalid - too long
        #expect(throws: MCPError.self) {
            try validator.validate(.string("ABCD"), against: schema)
        }
    }

    // MARK: - Number Schemas

    @Test("Validates number type")
    func numberType() throws {
        let schema: Value = ["type": "number"]

        // Valid
        try validator.validate(.int(42), against: schema)
        try validator.validate(.double(3.14), against: schema)

        // Invalid - string instead of number
        #expect(throws: MCPError.self) {
            try validator.validate(.string("42"), against: schema)
        }
    }

    @Test("Validates integer type")
    func integerType() throws {
        let schema: Value = ["type": "integer"]

        // Valid
        try validator.validate(.int(42), against: schema)

        // Invalid - decimal
        #expect(throws: MCPError.self) {
            try validator.validate(.double(3.14), against: schema)
        }
    }

    @Test("Validates number range")
    func numberRange() throws {
        let schema: Value = [
            "type": "number",
            "minimum": 0,
            "maximum": 100,
        ]

        // Valid
        try validator.validate(.int(0), against: schema)
        try validator.validate(.int(50), against: schema)
        try validator.validate(.int(100), against: schema)

        // Invalid - below minimum
        #expect(throws: MCPError.self) {
            try validator.validate(.int(-1), against: schema)
        }

        // Invalid - above maximum
        #expect(throws: MCPError.self) {
            try validator.validate(.int(101), against: schema)
        }
    }

    // MARK: - Boolean Schemas

    @Test("Validates boolean type")
    func booleanType() throws {
        let schema: Value = ["type": "boolean"]

        // Valid
        try validator.validate(.bool(true), against: schema)
        try validator.validate(.bool(false), against: schema)

        // Invalid - string
        #expect(throws: MCPError.self) {
            try validator.validate(.string("true"), against: schema)
        }

        // Invalid - number
        #expect(throws: MCPError.self) {
            try validator.validate(.int(1), against: schema)
        }
    }

    // MARK: - Enum Schemas

    @Test("Validates enum values")
    func enumValues() throws {
        let schema: Value = [
            "enum": ["red", "green", "blue"],
        ]

        // Valid
        try validator.validate(.string("red"), against: schema)
        try validator.validate(.string("green"), against: schema)
        try validator.validate(.string("blue"), against: schema)

        // Invalid
        #expect(throws: MCPError.self) {
            try validator.validate(.string("yellow"), against: schema)
        }
    }

    @Test("Validates enum with mixed types")
    func enumMixedTypes() throws {
        let schema: Value = [
            "enum": ["option1", 42, true, .null],
        ]

        // Valid
        try validator.validate(.string("option1"), against: schema)
        try validator.validate(.int(42), against: schema)
        try validator.validate(.bool(true), against: schema)
        try validator.validate(.null, against: schema)

        // Invalid
        #expect(throws: MCPError.self) {
            try validator.validate(.string("other"), against: schema)
        }
    }

    // MARK: - Object Schemas

    @Test("Validates simple object with required fields")
    func simpleObject() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "number"],
            ],
            "required": ["name"],
        ]

        // Valid - all fields
        try validator.validate(
            .object(["name": .string("John"), "age": .int(30)]),
            against: schema
        )

        // Valid - required only
        try validator.validate(
            .object(["name": .string("John")]),
            against: schema
        )

        // Invalid - missing required field
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object(["age": .int(30)]),
                against: schema
            )
        }

        // Invalid - empty object
        #expect(throws: MCPError.self) {
            try validator.validate(.object([:]), against: schema)
        }
    }

    @Test("Validates nested objects")
    func nestedObjects() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "user": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "email": ["type": "string"],
                    ],
                    "required": ["name"],
                ],
            ],
            "required": ["user"],
        ]

        // Valid
        try validator.validate(
            .object([
                "user": .object([
                    "name": .string("John"),
                    "email": .string("john@example.com"),
                ]),
            ]),
            against: schema
        )

        // Invalid - nested required field missing
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "user": .object([
                        "email": .string("john@example.com"),
                    ]),
                ]),
                against: schema
            )
        }
    }

    @Test("Validates object with additionalProperties: false")
    func additionalPropertiesFalse() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
            ],
            "additionalProperties": false,
        ]

        // Valid
        try validator.validate(
            .object(["name": .string("John")]),
            against: schema
        )

        // Invalid - extra field
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object(["name": .string("John"), "extra": .string("field")]),
                against: schema
            )
        }
    }

    // MARK: - Array Schemas

    @Test("Validates array of strings")
    func arrayOfStrings() throws {
        let schema: Value = [
            "type": "array",
            "items": ["type": "string"],
        ]

        // Valid
        try validator.validate(.array([.string("a"), .string("b"), .string("c")]), against: schema)
        try validator.validate(.array([]), against: schema)

        // Invalid - mixed types
        #expect(throws: MCPError.self) {
            try validator.validate(.array([.string("a"), .int(1), .string("c")]), against: schema)
        }
    }

    @Test("Validates array length constraints")
    func arrayLengthConstraints() throws {
        let schema: Value = [
            "type": "array",
            "items": ["type": "number"],
            "minItems": 1,
            "maxItems": 3,
        ]

        // Valid
        try validator.validate(.array([.int(1)]), against: schema)
        try validator.validate(.array([.int(1), .int(2), .int(3)]), against: schema)

        // Invalid - too few
        #expect(throws: MCPError.self) {
            try validator.validate(.array([]), against: schema)
        }

        // Invalid - too many
        #expect(throws: MCPError.self) {
            try validator.validate(.array([.int(1), .int(2), .int(3), .int(4)]), against: schema)
        }
    }

    @Test("Validates array with unique items")
    func arrayUniqueItems() throws {
        let schema: Value = [
            "type": "array",
            "items": ["type": "number"],
            "uniqueItems": true,
        ]

        // Valid
        try validator.validate(.array([.int(1), .int(2), .int(3)]), against: schema)

        // Invalid - duplicates
        #expect(throws: MCPError.self) {
            try validator.validate(.array([.int(1), .int(2), .int(2), .int(3)]), against: schema)
        }
    }

    // MARK: - JSON Schema 2020-12 Features

    @Test("Validates with allOf")
    func allOf() throws {
        let schema: Value = [
            "allOf": [
                ["type": "object", "properties": ["name": ["type": "string"]]],
                ["type": "object", "properties": ["age": ["type": "number"]]],
            ],
        ]

        // Valid
        try validator.validate(
            .object(["name": .string("John"), "age": .int(30)]),
            against: schema
        )
        try validator.validate(
            .object(["name": .string("John")]),
            against: schema
        )

        // Invalid - wrong type for name
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object(["name": .int(123)]),
                against: schema
            )
        }
    }

    @Test("Validates with anyOf")
    func anyOf() throws {
        let schema: Value = [
            "anyOf": [
                ["type": "string"],
                ["type": "number"],
            ],
        ]

        // Valid
        try validator.validate(.string("test"), against: schema)
        try validator.validate(.int(42), against: schema)

        // Invalid
        #expect(throws: MCPError.self) {
            try validator.validate(.bool(true), against: schema)
        }
    }

    @Test("Validates with oneOf")
    func oneOf() throws {
        let schema: Value = [
            "oneOf": [
                ["type": "string", "minLength": 5],
                ["type": "string", "maxLength": 3],
            ],
        ]

        // Valid - matches second only
        try validator.validate(.string("ab"), against: schema)

        // Valid - matches first only
        try validator.validate(.string("hello"), against: schema)

        // Invalid - matches neither
        #expect(throws: MCPError.self) {
            try validator.validate(.string("abcd"), against: schema)
        }
    }

    @Test("Validates with not")
    func notConstraint() throws {
        let schema: Value = [
            "not": ["type": "null"],
        ]

        // Valid
        try validator.validate(.string("test"), against: schema)
        try validator.validate(.int(42), against: schema)

        // Invalid
        #expect(throws: MCPError.self) {
            try validator.validate(.null, against: schema)
        }
    }

    @Test("Validates with const")
    func constValue() throws {
        let schema: Value = [
            "const": "specific-value",
        ]

        // Valid
        try validator.validate(.string("specific-value"), against: schema)

        // Invalid
        #expect(throws: MCPError.self) {
            try validator.validate(.string("other-value"), against: schema)
        }
    }

    // MARK: - Complex Real-World Schemas

    @Test("Validates user registration form schema")
    func userRegistrationForm() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "username": [
                    "type": "string",
                    "minLength": 3,
                    "maxLength": 20,
                    "pattern": "^[a-zA-Z0-9_]+$",
                ],
                "email": [
                    "type": "string",
                ],
                "age": [
                    "type": "integer",
                    "minimum": 18,
                    "maximum": 120,
                ],
                "newsletter": [
                    "type": "boolean",
                ],
            ],
            "required": ["username", "email"],
        ]

        // Valid - all fields
        try validator.validate(
            .object([
                "username": .string("john_doe"),
                "email": .string("john@example.com"),
                "age": .int(25),
                "newsletter": .bool(true),
            ]),
            against: schema
        )

        // Valid - required only
        try validator.validate(
            .object([
                "username": .string("john_doe"),
                "email": .string("john@example.com"),
            ]),
            against: schema
        )

        // Invalid - username too short
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "username": .string("ab"),
                    "email": .string("john@example.com"),
                ]),
                against: schema
            )
        }

        // Invalid - age out of range
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "username": .string("john_doe"),
                    "email": .string("john@example.com"),
                    "age": .int(15),
                ]),
                against: schema
            )
        }
    }

    @Test("Validates API response with nested structure")
    func apiResponseSchema() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "status": [
                    "type": "string",
                    "enum": ["success", "error", "pending"],
                ],
                "data": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "items": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "quantity": ["type": "integer", "minimum": 1],
                                ],
                                "required": ["name", "quantity"],
                            ],
                        ],
                    ],
                    "required": ["id", "items"],
                ],
            ],
            "required": ["status", "data"],
        ]

        // Valid
        try validator.validate(
            .object([
                "status": .string("success"),
                "data": .object([
                    "id": .string("123"),
                    "items": .array([
                        .object(["name": .string("Item 1"), "quantity": .int(5)]),
                        .object(["name": .string("Item 2"), "quantity": .int(3)]),
                    ]),
                ]),
            ]),
            against: schema
        )

        // Invalid - wrong status enum
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "status": .string("invalid-status"),
                    "data": .object([
                        "id": .string("123"),
                        "items": .array([]),
                    ]),
                ]),
                against: schema
            )
        }
    }

    // MARK: - Error Messages

    @Test("Provides helpful error message on validation failure")
    func errorMessages() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
            ],
            "required": ["name"],
        ]

        do {
            try validator.validate(.object([:]), against: schema)
            Issue.record("Expected validation to fail")
        } catch let error as MCPError {
            // Should have an error message
            let message = error.localizedDescription
            #expect(!message.isEmpty)
        }
    }

    // MARK: - Schema Caching

    @Test("Caches compiled schemas for repeated validation")
    func schemaCaching() throws {
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
            ],
            "required": ["name"],
        ]

        // First validation - compiles schema
        try validator.validate(.object(["name": .string("John")]), against: schema)

        // Second validation - should use cached schema
        try validator.validate(.object(["name": .string("Jane")]), against: schema)

        // Third validation with invalid data - should still use cached schema
        #expect(throws: MCPError.self) {
            try validator.validate(.object([:]), against: schema)
        }
    }
}

// MARK: - Tool Input Validation Tests

@Suite("Tool Input Validation Tests")
struct ToolInputValidationTests {
    @Test("Valid tool call passes input validation")
    func validToolCall() throws {
        let validator = DefaultJSONSchemaValidator()
        let inputSchema: Value = [
            "type": "object",
            "properties": [
                "a": ["type": "number"],
                "b": ["type": "number"],
            ],
            "required": ["a", "b"],
            "additionalProperties": false,
        ]

        let arguments: Value = .object([
            "a": .int(5),
            "b": .int(3),
        ])

        // Should not throw
        try validator.validate(arguments, against: inputSchema)
    }

    @Test("Missing required argument fails validation")
    func missingRequiredArgument() throws {
        let validator = DefaultJSONSchemaValidator()
        let inputSchema: Value = [
            "type": "object",
            "properties": [
                "a": ["type": "number"],
                "b": ["type": "number"],
            ],
            "required": ["a", "b"],
        ]

        let arguments: Value = .object([
            "a": .int(5),
            // Missing 'b'
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(arguments, against: inputSchema)
        }
    }

    @Test("Wrong argument type fails validation")
    func wrongArgumentType() throws {
        let validator = DefaultJSONSchemaValidator()
        let inputSchema: Value = [
            "type": "object",
            "properties": [
                "a": ["type": "number"],
                "b": ["type": "number"],
            ],
            "required": ["a", "b"],
        ]

        let arguments: Value = .object([
            "a": .string("five"), // Should be number
            "b": .int(3),
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(arguments, against: inputSchema)
        }
    }

    @Test("Invalid enum value fails validation")
    func invalidEnumValue() throws {
        let validator = DefaultJSONSchemaValidator()
        let inputSchema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "title": ["type": "string", "enum": ["Mr", "Ms", "Dr"]],
            ],
            "required": ["name"],
        ]

        let arguments: Value = .object([
            "name": .string("Smith"),
            "title": .string("Prof"), // Not in enum
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(arguments, against: inputSchema)
        }
    }

    @Test("Additional properties rejected when forbidden")
    func additionalPropertiesRejected() throws {
        let validator = DefaultJSONSchemaValidator()
        let inputSchema: Value = [
            "type": "object",
            "properties": [
                "a": ["type": "number"],
                "b": ["type": "number"],
            ],
            "required": ["a", "b"],
            "additionalProperties": false,
        ]

        let arguments: Value = .object([
            "a": .int(5),
            "b": .int(3),
            "c": .int(10), // Extra property not allowed
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(arguments, against: inputSchema)
        }
    }
}

// MARK: - Tool Output Validation Tests

@Suite("Tool Output Validation Tests")
struct ToolOutputValidationTests {
    @Test("Valid structured output passes validation")
    func validStructuredOutput() throws {
        let validator = DefaultJSONSchemaValidator()
        let outputSchema: Value = [
            "type": "object",
            "properties": [
                "sum": ["type": "number"],
                "product": ["type": "number"],
            ],
            "required": ["sum", "product"],
        ]

        let structuredContent: Value = .object([
            "sum": .int(7),
            "product": .int(12),
        ])

        try validator.validate(structuredContent, against: outputSchema)
    }

    @Test("Missing required field in output fails validation")
    func missingRequiredOutputField() throws {
        let validator = DefaultJSONSchemaValidator()
        let outputSchema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "integer"],
            ],
            "required": ["name", "age"],
        ]

        let structuredContent: Value = .object([
            "name": .string("Alice"),
            // Missing required 'age'
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(structuredContent, against: outputSchema)
        }
    }

    @Test("Wrong type in output fails validation")
    func wrongOutputType() throws {
        let validator = DefaultJSONSchemaValidator()
        let outputSchema: Value = [
            "type": "object",
            "properties": [
                "count": ["type": "integer"],
                "average": ["type": "number"],
                "items": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["count", "average", "items"],
        ]

        let structuredContent: Value = .object([
            "count": .string("five"), // Should be integer
            "average": .double(2.5),
            "items": .array([.string("a"), .string("b")]),
        ])

        #expect(throws: MCPError.self) {
            try validator.validate(structuredContent, against: outputSchema)
        }
    }

    @Test("Complex output schema validation")
    func complexOutputSchema() throws {
        let validator = DefaultJSONSchemaValidator()
        let outputSchema: Value = [
            "type": "object",
            "properties": [
                "sentiment": ["type": "string", "enum": ["positive", "negative", "neutral"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            ],
            "required": ["sentiment", "confidence"],
        ]

        // Valid
        try validator.validate(
            .object([
                "sentiment": .string("positive"),
                "confidence": .double(0.95),
            ]),
            against: outputSchema
        )

        // Invalid - confidence out of range
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "sentiment": .string("positive"),
                    "confidence": .double(1.5),
                ]),
                against: outputSchema
            )
        }

        // Invalid - wrong sentiment enum
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "sentiment": .string("happy"),
                    "confidence": .double(0.8),
                ]),
                against: outputSchema
            )
        }
    }
}

// MARK: - Elicitation Validation Tests

@Suite("Elicitation Schema Validation Tests")
struct ElicitationValidationTests {
    @Test("Simple string field validation")
    func simpleStringField() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "minLength": 1],
            ],
            "required": ["name"],
        ]

        // Valid
        try validator.validate(.object(["name": .string("John Doe")]), against: schema)

        // Invalid - empty string
        #expect(throws: MCPError.self) {
            try validator.validate(.object(["name": .string("")]), against: schema)
        }
    }

    @Test("Integer field with range validation")
    func integerFieldWithRange() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "age": ["type": "integer", "minimum": 0, "maximum": 150],
            ],
            "required": ["age"],
        ]

        // Valid
        try validator.validate(.object(["age": .int(42)]), against: schema)

        // Invalid - too high
        #expect(throws: MCPError.self) {
            try validator.validate(.object(["age": .int(200)]), against: schema)
        }
    }

    @Test("Boolean field validation")
    func booleanField() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "agree": ["type": "boolean"],
            ],
            "required": ["agree"],
        ]

        // Valid
        try validator.validate(.object(["agree": .bool(true)]), against: schema)
        try validator.validate(.object(["agree": .bool(false)]), against: schema)

        // Invalid - string instead of boolean
        #expect(throws: MCPError.self) {
            try validator.validate(.object(["agree": .string("true")]), against: schema)
        }
    }

    @Test("Complex multi-field form validation")
    func complexMultiFieldForm() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "minLength": 1],
                "email": ["type": "string"],
                "age": ["type": "integer", "minimum": 0, "maximum": 150],
                "newsletter": ["type": "boolean"],
            ],
            "required": ["name", "email", "age"],
        ]

        // Valid - all fields
        try validator.validate(
            .object([
                "name": .string("Jane Smith"),
                "email": .string("jane@example.com"),
                "age": .int(28),
                "newsletter": .bool(true),
            ]),
            against: schema
        )

        // Valid - required only
        try validator.validate(
            .object([
                "name": .string("Jane Smith"),
                "email": .string("jane@example.com"),
                "age": .int(28),
            ]),
            against: schema
        )
    }

    @Test("Missing required field rejected")
    func missingRequiredField() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "email": ["type": "string"],
            ],
            "required": ["name", "email"],
        ]

        // Missing 'name'
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object(["email": .string("user@example.com")]),
                against: schema
            )
        }
    }

    @Test("Invalid field type rejected")
    func invalidFieldType() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "integer"],
            ],
            "required": ["name", "age"],
        ]

        // age is string instead of integer
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object([
                    "name": .string("John Doe"),
                    "age": .string("thirty"),
                ]),
                against: schema
            )
        }
    }

    @Test("Single-select enum validation")
    func singleSelectEnum() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "color": [
                    "type": "string",
                    "enum": ["Red", "Green", "Blue"],
                ],
            ],
            "required": ["color"],
        ]

        // Valid
        try validator.validate(.object(["color": .string("Red")]), against: schema)

        // Invalid - not in enum
        #expect(throws: MCPError.self) {
            try validator.validate(.object(["color": .string("Black")]), against: schema)
        }
    }

    @Test("Multi-select enum validation")
    func multiSelectEnum() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "colors": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 3,
                    "items": [
                        "type": "string",
                        "enum": ["Red", "Green", "Blue"],
                    ],
                ],
            ],
            "required": ["colors"],
        ]

        // Valid
        try validator.validate(
            .object(["colors": .array([.string("Red"), .string("Blue")])]),
            against: schema
        )

        // Invalid - value not in enum
        #expect(throws: MCPError.self) {
            try validator.validate(
                .object(["colors": .array([.string("Red"), .string("Black")])]),
                against: schema
            )
        }
    }

    @Test("Titled enum with oneOf validation")
    func titledEnumWithOneOf() throws {
        let validator = DefaultJSONSchemaValidator()
        let schema: Value = [
            "type": "object",
            "properties": [
                "color": [
                    "type": "string",
                    "oneOf": [
                        ["const": "#FF0000", "title": "Red"],
                        ["const": "#00FF00", "title": "Green"],
                        ["const": "#0000FF", "title": "Blue"],
                    ],
                ],
            ],
            "required": ["color"],
        ]

        // Valid - using const value
        try validator.validate(.object(["color": .string("#FF0000")]), against: schema)

        // Invalid - using title instead of const
        #expect(throws: MCPError.self) {
            try validator.validate(.object(["color": .string("Red")]), against: schema)
        }
    }
}

// MARK: - Value.toJSONValue() Tests

@Suite("Value to JSONValue Conversion Tests")
struct ValueToJSONValueTests {
    @Test("Converts null value")
    func nullValue() throws {
        let value: Value = .null
        let jsonValue = value.toJSONValue()
        #expect(jsonValue == .null)
    }

    @Test("Converts boolean values")
    func booleanValues() throws {
        #expect(Value.bool(true).toJSONValue() == .boolean(true))
        #expect(Value.bool(false).toJSONValue() == .boolean(false))
    }

    @Test("Converts integer values")
    func integerValues() throws {
        #expect(Value.int(42).toJSONValue() == .integer(42))
        #expect(Value.int(-10).toJSONValue() == .integer(-10))
        #expect(Value.int(0).toJSONValue() == .integer(0))
    }

    @Test("Converts double values")
    func doubleValues() throws {
        #expect(Value.double(3.14).toJSONValue() == .number(3.14))
        #expect(Value.double(-2.5).toJSONValue() == .number(-2.5))
    }

    @Test("Converts string values")
    func stringValues() throws {
        #expect(Value.string("hello").toJSONValue() == .string("hello"))
        #expect(Value.string("").toJSONValue() == .string(""))
        #expect(Value.string("Unicode: 你好").toJSONValue() == .string("Unicode: 你好"))
    }

    @Test("Converts array values")
    func arrayValues() throws {
        let value: Value = .array([.int(1), .string("two"), .bool(true)])
        let jsonValue = value.toJSONValue()

        if case let .array(elements) = jsonValue {
            #expect(elements.count == 3)
            #expect(elements[0] == .integer(1))
            #expect(elements[1] == .string("two"))
            #expect(elements[2] == .boolean(true))
        } else {
            Issue.record("Expected array JSONValue")
        }
    }

    @Test("Converts object values")
    func objectValues() throws {
        let value: Value = .object([
            "name": .string("John"),
            "age": .int(30),
            "active": .bool(true),
        ])
        let jsonValue = value.toJSONValue()

        if case let .object(dict) = jsonValue {
            #expect(dict["name"] == .string("John"))
            #expect(dict["age"] == .integer(30))
            #expect(dict["active"] == .boolean(true))
        } else {
            Issue.record("Expected object JSONValue")
        }
    }

    @Test("Converts nested structures")
    func nestedStructures() throws {
        let value: Value = .object([
            "user": .object([
                "name": .string("Alice"),
                "tags": .array([.string("admin"), .string("user")]),
            ]),
            "count": .int(5),
        ])
        let jsonValue = value.toJSONValue()

        if case let .object(dict) = jsonValue,
           case let .object(user) = dict["user"],
           case let .array(tags) = user["tags"]
        {
            #expect(user["name"] == .string("Alice"))
            #expect(tags.count == 2)
            #expect(tags[0] == .string("admin"))
        } else {
            Issue.record("Expected nested structure")
        }
    }
}
