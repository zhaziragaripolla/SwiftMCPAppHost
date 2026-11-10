public import Foundation

/// What your app provides to the MCP Apps it shows. Usually your MCP client and your chat UI.
///
/// Only ``callTool(name:arguments:)`` is required. Every other method has a default that refuses
/// or ignores the request, so an app gets nothing it didn't ask for and you didn't allow.
@MainActor
public protocol MCPAppHostDelegate: AnyObject {
    /// The app called a tool on its MCP server (`tools/call`). Forward it through your MCP client
    /// and return the `CallToolResult` (`{"content": […], "structuredContent": …}`).
    /// Throw ``MCPAppError`` to send a specific JSON-RPC error.
    func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON

    /// The app read a resource (`resources/read`). Default: refused.
    func readResource(uri: String) async throws -> MCPJSON

    /// The app asked to open a link (`ui/open-link`). Return true once you've opened it, or false
    /// to refuse. The URL has already been checked to be `http`, `https` or `mailto`. Default: refused.
    func openLink(_ url: URL) async -> Bool

    /// The app sent a message for the conversation (`ui/message`), e.g.
    /// `{"role": "user", "content": {"type": "text", "text": "…"}}`.
    /// Return true to accept it. Default: refused.
    func receiveMessage(_ message: MCPJSON) async -> Bool

    /// The app updated the context it wants the model to see (`ui/update-model-context`).
    /// Each call replaces the previous one. Default: ignored.
    func updateModelContext(_ context: MCPJSON) async

    /// The app asked for a different display mode (`ui/request-display-mode`). Return the mode
    /// you actually switched to. Default: stays in the current mode.
    func requestDisplayMode(_ mode: MCPAppDisplayMode, current: MCPAppDisplayMode) async -> MCPAppDisplayMode

    /// The app logged something (`notifications/message`). Default: ignored.
    func didReceiveLog(_ params: MCPJSON?)

    /// The app asked to be closed (`ui/notifications/request-teardown`). Default: ignored.
    func appDidRequestTeardown()

    /// Something the host noticed and handled: dropped messages, timeouts, rejected domains.
    /// For logs and debugging. Default: ignored.
    func didReport(_ diagnostic: MCPAppDiagnostic)
}

public extension MCPAppHostDelegate {
    func readResource(uri: String) async throws -> MCPJSON { throw MCPAppError.denied("Resource reading is not available") }
    func openLink(_ url: URL) async -> Bool { false }
    func receiveMessage(_ message: MCPJSON) async -> Bool { false }
    func updateModelContext(_ context: MCPJSON) async {}
    func requestDisplayMode(_ mode: MCPAppDisplayMode, current: MCPAppDisplayMode) async -> MCPAppDisplayMode { current }
    func didReceiveLog(_ params: MCPJSON?) {}
    func appDidRequestTeardown() {}
    func didReport(_ diagnostic: MCPAppDiagnostic) {}
}

/// Something the host noticed and handled without involving the app.
public enum MCPAppDiagnostic: Sendable, Hashable, CustomStringConvertible {
    case invalidJSON
    case notJSONRPC
    case messageTooLarge(bytes: Int, limit: Int)
    case unknownRequest(method: String)
    case unknownNotification(method: String)
    case unexpectedResponse(id: MCPJSON)
    case duplicateInitialize
    case requestBeforeInitialize(method: String)
    case handshakeTimedOut
    case requestTimedOut(method: String)
    case rejectedCSPDomain(String)
    case blockedNavigation(String)
    case refusedPermission(String)
    case messageFromSubframe
    case webContentProcessTerminated

    public var description: String {
        switch self {
        case .invalidJSON: "Dropped a message that isn't valid JSON"
        case .notJSONRPC: "Dropped a message that isn't JSON-RPC 2.0"
        case .messageTooLarge(let n, let limit): "Dropped a \(n)-byte message (limit \(limit))"
        case .unknownRequest(let m): "Answered unknown request \(m) with method-not-found"
        case .unknownNotification(let m): "Ignored unknown notification \(m)"
        case .unexpectedResponse: "Ignored a response to no pending request"
        case .duplicateInitialize: "The app sent ui/initialize more than once"
        case .requestBeforeInitialize(let m): "The app sent \(m) before ui/initialize"
        case .handshakeTimedOut: "The app didn't finish initializing in time"
        case .requestTimedOut(let m): "The app didn't answer \(m) in time"
        case .rejectedCSPDomain(let d): "Dropped an invalid CSP domain: \(d)"
        case .blockedNavigation(let u): "Blocked navigation to \(u)"
        case .refusedPermission(let p): "Refused \(p)"
        case .messageFromSubframe: "Dropped a message from a sub-frame"
        case .webContentProcessTerminated: "The web content process ended"
        }
    }
}
