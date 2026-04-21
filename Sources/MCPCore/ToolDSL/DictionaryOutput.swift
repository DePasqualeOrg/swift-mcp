// Copyright © Anthony DePasquale

import Foundation

/// Narrow internal marker for tool-output types whose JSON form is already a
/// top-level object and must not be re-wrapped under `"result"`.
///
/// The only conformer today is `Dictionary<String, V>` where `V: WrappableValue`,
/// mirroring Pydantic's `RootModel[dict[str, T]]` in the Python SDK. Used by
/// `MCPSchema.outputSchema(for:)` to select the unwrapped-schema path in a
/// single type-check.
protocol UnwrappedObjectOutput: WrappableValue {}

// MARK: - Dictionary<String, V>

extension Dictionary: WrappableValue where Key == String, Value: WrappableValue {
    public static var valueSchema: MCPCore.Value {
        .object([
            "type": .string("object"),
            "additionalProperties": Value.valueSchema,
        ])
    }

    public func asJSONValue() throws -> MCPCore.Value {
        var object: [String: MCPCore.Value] = [:]
        object.reserveCapacity(count)
        for (key, value) in self {
            object[key] = try value.asJSONValue()
        }
        return .object(object)
    }

    public func asDisplayText() throws -> String {
        try prettyPrintedJSON(self)
    }
}

extension Dictionary: UnwrappedObjectOutput where Key == String, Value: WrappableValue {}

extension Dictionary: ToolOutput where Key == String, Value: WrappableValue {
    public func toCallToolResult() throws -> CallTool.Result {
        try CallTool.Result(
            content: [.text(asDisplayText())],
            structuredContent: asJSONValue(),
        )
    }
}
