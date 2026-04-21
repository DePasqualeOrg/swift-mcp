// Copyright © Anthony DePasquale

// Re-export MCPCore so that existing code importing `MCP` continues to see all
// types and protocols that moved to the `MCPCore` target.
//
// Consumers who only need the contract types (e.g. to define tool result
// structs) can depend on `MCPCore` directly and skip the client/server/
// transport runtime.
@_exported import MCPCore

// MARK: - Name-collision aliases

//
// `Notification` and `Method` in MCPCore collide with Foundation's own
// `Notification` struct and Objective-C runtime's `Method` type when a file
// imports both `Foundation` and `MCPCore`. Inside this module we consistently
// resolve the collision by using the module qualifier `MCPCore.Notification`
// and `MCPCore.Method` at every reference site. The type aliases below are
// intentionally omitted — adding them re-introduces the ambiguity.
