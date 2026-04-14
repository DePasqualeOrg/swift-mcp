// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
import MCPTool
import Testing

// MARK: - @Schemable test types

@Schemable
struct SchemableIntegrationMoney: Equatable {
    let amount: Double
    let currency: String
}

@Schemable
struct SchemableIntegrationAddress: Equatable {
    let street: String
    let city: String
}

@Schemable
struct SchemableIntegrationContact: Equatable {
    let name: String
    let address: SchemableIntegrationAddress
}

@Schemable
enum SchemableIntegrationFileEdit: Equatable {
    case insert(line: Int, text: String)
    case delete(startLine: Int, endLine: Int)
}

// MARK: - Tools using the types above

@Tool
struct SchemableIntegrationSubmitPayment {
    static let name = "submit_payment"
    static let description = "Submit a payment with the given amount and currency"

    @Parameter(description: "Payment amount in the chosen currency")
    var payment: SchemableIntegrationMoney

    func perform() async throws -> String {
        "Paid \(payment.amount) \(payment.currency)"
    }
}

@Tool
struct SchemableIntegrationApplyFileEdit {
    static let name = "apply_file_edit"
    static let description = "Apply an edit operation to a file"

    @Parameter(description: "The edit to apply")
    var edit: SchemableIntegrationFileEdit

    func perform() async throws -> String {
        switch edit {
            case let .insert(line, text): "insert@\(line): \(text)"
            case let .delete(start, end): "delete \(start)..\(end)"
        }
    }
}

@Tool
struct SchemableIntegrationRegisterContact {
    static let name = "register_contact"
    static let description = "Register a contact with nested address"

    @Parameter(description: "The contact to register")
    var contact: SchemableIntegrationContact

    func perform() async throws -> String {
        "\(contact.name) at \(contact.address.street), \(contact.address.city)"
    }
}

// MARK: - Tests

struct SchemableIntegrationTests {
    // MARK: Primitive-wrapping struct

    @Test
    func `Tool with primitive-wrapping struct generates nested object schema`() {
        let definition = SchemableIntegrationSubmitPayment.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let paymentProp = properties?["payment"]?.objectValue
        #expect(paymentProp?["type"]?.stringValue == "object")

        let nestedProps = paymentProp?["properties"]?.objectValue
        #expect(nestedProps?["amount"]?.objectValue?["type"]?.stringValue == "number")
        #expect(nestedProps?["currency"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test
    func `Tool with primitive-wrapping struct parses nested object`() async throws {
        let arguments: [String: Value] = [
            "payment": .object([
                "amount": .double(42.5),
                "currency": .string("USD"),
            ]),
        ]

        let instance = try SchemableIntegrationSubmitPayment.parse(from: arguments)
        #expect(instance.payment == SchemableIntegrationMoney(amount: 42.5, currency: "USD"))

        let result = try await instance.perform()
        #expect(result == "Paid 42.5 USD")
    }

    // MARK: Associated-value enum

    @Test
    func `Tool with associated-value enum generates oneOf schema`() {
        let definition = SchemableIntegrationApplyFileEdit.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let editProp = properties?["edit"]?.objectValue

        let oneOf = editProp?["oneOf"]?.arrayValue
        #expect(oneOf?.count == 2)

        let caseKeys = oneOf?.compactMap { variant -> String? in
            guard let props = variant.objectValue?["properties"]?.objectValue else { return nil }
            return props.keys.first
        } ?? []
        #expect(Set(caseKeys) == ["insert", "delete"])
    }

    @Test
    func `Tool with associated-value enum parses each case`() async throws {
        let insertArgs: [String: Value] = [
            "edit": .object([
                "insert": .object([
                    "line": .int(3),
                    "text": .string("hello"),
                ]),
            ]),
        ]
        let insertInstance = try SchemableIntegrationApplyFileEdit.parse(from: insertArgs)
        #expect(insertInstance.edit == .insert(line: 3, text: "hello"))
        #expect(try await insertInstance.perform() == "insert@3: hello")

        let deleteArgs: [String: Value] = [
            "edit": .object([
                "delete": .object([
                    "startLine": .int(5),
                    "endLine": .int(10),
                ]),
            ]),
        ]
        let deleteInstance = try SchemableIntegrationApplyFileEdit.parse(from: deleteArgs)
        #expect(deleteInstance.edit == .delete(startLine: 5, endLine: 10))
        #expect(try await deleteInstance.perform() == "delete 5..10")
    }

    // MARK: Nested Schemable struct

    @Test
    func `Tool with nested Schemable struct generates nested schema`() {
        let definition = SchemableIntegrationRegisterContact.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let contactProp = properties?["contact"]?.objectValue

        #expect(contactProp?["type"]?.stringValue == "object")
        let contactProps = contactProp?["properties"]?.objectValue
        #expect(contactProps?["name"]?.objectValue?["type"]?.stringValue == "string")

        let addressProp = contactProps?["address"]?.objectValue
        #expect(addressProp?["type"]?.stringValue == "object")
        let addressProps = addressProp?["properties"]?.objectValue
        #expect(addressProps?["street"]?.objectValue?["type"]?.stringValue == "string")
        #expect(addressProps?["city"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test
    func `Tool with nested Schemable struct parses nested data`() async throws {
        let arguments: [String: Value] = [
            "contact": .object([
                "name": .string("Alice"),
                "address": .object([
                    "street": .string("1 Main St"),
                    "city": .string("Paris"),
                ]),
            ]),
        ]

        let instance = try SchemableIntegrationRegisterContact.parse(from: arguments)
        #expect(instance.contact == SchemableIntegrationContact(
            name: "Alice",
            address: SchemableIntegrationAddress(street: "1 Main St", city: "Paris"),
        ))
        #expect(try await instance.perform() == "Alice at 1 Main St, Paris")
    }

    // MARK: Strict-mode normalization

    @Test
    func `Build returns raw schema for primitive-wrapping struct`() throws {
        // `buildObjectSchema` always returns the raw form — MCP is a
        // provider-agnostic wire format, so OpenAI strict-mode normalization
        // happens on the client side of the wire.
        let descriptor = ToolMacroSupport.makeSchemaParameterDescriptor(
            name: "payment",
            description: "Payment",
            schema: SchemableIntegrationMoney.schema,
            isOptional: false,
        )
        let schema = try ToolMacroSupport.buildObjectSchema(parameters: [descriptor])
        #expect(schema["additionalProperties"] == nil)
        let requiredArray = try #require(schema["required"]?.arrayValue)
        let required = requiredArray.compactMap(\.stringValue)
        #expect(required.contains("payment"))

        // Opt-in validation doesn't alter the schema; downstream normalizer adds the
        // strict-mode constraints when OpenAI clients send it.
        try ToolMacroSupport.validateStrictCompatibility(schema, toolName: "submit_payment")
        let normalized = try ToolSchema.normalizeForStrictMode(schema)
        #expect(normalized["additionalProperties"]?.boolValue == false)
    }

    @Test
    func `Strict-mode validation passes for associated-value enum schema`() throws {
        let descriptor = ToolMacroSupport.makeSchemaParameterDescriptor(
            name: "edit",
            description: "Edit",
            schema: SchemableIntegrationFileEdit.schema,
            isOptional: false,
        )
        let schema = try ToolMacroSupport.buildObjectSchema(parameters: [descriptor])
        #expect(schema["additionalProperties"] == nil)
        let properties = try #require(schema["properties"]?.objectValue)
        let editProp = try #require(properties["edit"]?.objectValue)
        #expect(editProp["oneOf"] != nil)

        // Opt-in validation accepts this shape; normalizer also succeeds.
        try ToolMacroSupport.validateStrictCompatibility(schema, toolName: "apply_file_edit")
        let normalized = try ToolSchema.normalizeForStrictMode(schema)
        #expect(normalized["additionalProperties"]?.boolValue == false)
    }

    @Test
    func `Strict-mode normalization succeeds on nested Schemable struct schema`() throws {
        let descriptor = ToolMacroSupport.makeSchemaParameterDescriptor(
            name: "contact",
            description: "Contact",
            schema: SchemableIntegrationContact.schema,
            isOptional: false,
        )
        let schema = try ToolMacroSupport.buildObjectSchema(parameters: [descriptor])
        // Nested objects pick up `additionalProperties: false` only after
        // normalization, not at build time.
        let normalized = try ToolSchema.normalizeForStrictMode(schema)
        let properties = try #require(normalized["properties"]?.objectValue)
        let contactProp = try #require(properties["contact"]?.objectValue)
        #expect(contactProp["additionalProperties"]?.boolValue == false)
        let nestedProps = try #require(contactProp["properties"]?.objectValue)
        let addressProp = try #require(nestedProps["address"]?.objectValue)
        #expect(addressProp["additionalProperties"]?.boolValue == false)
    }
}
