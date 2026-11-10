import Foundation
import SwiftUI
import Testing
@testable import SwiftMCPAppHost

// The integration shown in README.md, llms.txt, llms-full.txt, the Claude Code skill and the
// DocC articles, compiled here so the documentation can't drift from the API. If you change
// this file, update those documents too.

/// Stands in for the app's own MCP client.
struct MyMCPClient {
    func readResource(uri: String) async throws -> MCPJSON {
        ["contents": [["uri": .string(uri), "mimeType": "text/html;profile=mcp-app", "text": "<p>hi</p>"]]]
    }
    func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON {
        ["content": [["type": "text", "text": "done"]]]
    }
}

// --- README snippet: the delegate ---
@MainActor
final class AppHost: MCPAppHostDelegate {
    let client: MyMCPClient
    init(client: MyMCPClient) { self.client = client }

    // Required: the app called a tool on its server. Forward it through your MCP client.
    func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON {
        try await client.callTool(name: name, arguments: arguments)
    }

    // Optional: everything else is refused by default.
    func openLink(_ url: URL) async -> Bool {
        // e.g. await UIApplication.shared.open(url) on iOS
        true
    }
}

// --- README snippet: showing an app ---
@MainActor
func showApp(client: MyMCPClient, appHost: AppHost, uiURI: String,
             arguments: MCPJSON, callToolResult: MCPJSON) async throws -> MCPAppWebHost {
    // 1. Read the tool's UI resource (its _meta.ui.resourceUri) with your MCP client.
    let resource = try MCPAppResource(readResult: try await client.readResource(uri: uiURI))

    // 2. Create a host for it.
    let host = MCPAppWebHost(
        resource: resource,
        hostInfo: MCPAppHostInfo(name: "MyApp", version: "1.0"),
        delegate: appHost
    )

    // 3. Pass the tool call through. Held until the app finishes its handshake.
    host.bridge.sendToolInput(arguments)
    host.bridge.sendToolResult(callToolResult)
    return host
}

// --- README snippet: SwiftUI ---
struct ToolResultView: View {
    let host: MCPAppWebHost
    var body: some View {
        MCPAppView(host: host, maxHeight: 500)
    }
}

@Suite("Documentation snippets")
@MainActor
struct DocumentationSnippetTests {
    @Test func readmeIntegrationCompilesAndRuns() async throws {
        let client = MyMCPClient()
        let appHost = AppHost(client: client)
        let host = try await showApp(client: client, appHost: appHost, uiURI: "ui://weather/forecast",
                                     arguments: ["city": "Lisbon"], callToolResult: ["content": []])
        #expect(host.resource.uri == "ui://weather/forecast")
        #expect(host.bridge.state == .awaitingInitialize)
        _ = ToolResultView(host: host).body

        // --- README snippet: advertising support in your MCP initialize request ---
        let capabilities: MCPJSON = ["extensions": MCPAppProtocol.clientCapability]
        #expect(capabilities["extensions"]?["io.modelcontextprotocol/ui"] != nil)

        // --- README snippet: before removing it ---
        await host.teardown()
        #expect(host.bridge.state == .tornDown)
    }
}
