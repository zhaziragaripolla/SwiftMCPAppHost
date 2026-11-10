---
name: swift-mcp-app-host
description: Adds MCP Apps support to a native iOS app with the SwiftMCPAppHost Swift package. Use when an iOS or Swift app needs to show MCP Apps, MCP UI resources (ui:// URIs, text/html;profile=mcp-app), or interactive tool results from an MCP server with _meta.ui.resourceUri, in SwiftUI or UIKit.
---

# SwiftMCPAppHost

SwiftMCPAppHost shows MCP Apps (MCP extension SEP-1865, version 2026-01-26) inside a native iOS app: it renders the tool's HTML in a sandboxed `WKWebView` and runs the MCP Apps JSON-RPC protocol. It is not an MCP client; the app's existing client reads resources and executes tool calls.

Full reference: https://github.com/zhaziragaripolla/SwiftMCPAppHost/blob/main/llms-full.txt

## Steps

1. **Add the package** to the app target:
   ```swift
   .package(url: "https://github.com/zhaziragaripolla/SwiftMCPAppHost.git", from: "0.1.0"),
   ```

2. **Advertise support** in the MCP client's `initialize` capabilities, or servers won't return UIs:
   ```swift
   let capabilities: MCPJSON = ["extensions": MCPAppProtocol.clientCapability]
   ```

3. **Implement the delegate.** Only `callTool` is required; forward it to the MCP client. Add `openLink`, `receiveMessage` and the others only if the app should allow them.
   ```swift
   @MainActor
   final class AppHost: MCPAppHostDelegate {
       let client: MyMCPClient
       init(client: MyMCPClient) { self.client = client }
       func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON {
           try await client.callTool(name: name, arguments: arguments)
       }
   }
   ```

4. **When a tool with `_meta.ui.resourceUri` is called**, read that resource and create a host:
   ```swift
   let resource = try MCPAppResource(readResult: try await client.readResource(uri: uiURI))
   let host = MCPAppWebHost(resource: resource, hostInfo: MCPAppHostInfo(name: "MyApp", version: "1.0"), delegate: appHost)
   host.bridge.sendToolInput(arguments)
   host.bridge.sendToolResult(callToolResult)
   ```

5. **Show it** with `MCPAppView(host: host, maxHeight: 500)` in SwiftUI or `MCPAppHostView(host: host)` in UIKit. Keep the `MCPAppWebHost` alive (for example in `@State` or the message model) for as long as it's on screen.

6. **Before removing it**, `await host.teardown()`.

## Rules

- Never load MCP App HTML in a plain `WKWebView` or modify `host.webView`'s configuration or delegates: that removes the sandbox.
- Treat the app's HTML as untrusted. In `callTool`, apply the same permission checks as for model-initiated tool calls.
- Keep the delegate's refusing defaults unless the user asks for a capability. For `openLink`, open in the system browser and consider confirming with the user.
- Send `sendToolInput` before `sendToolResult`. Both may be sent right away; the bridge holds them until the handshake finishes.
- Camera, microphone, geolocation and clipboard are never granted; don't promise them.
- Check `didReport(_:)` diagnostics when an app doesn't appear or doesn't respond.
