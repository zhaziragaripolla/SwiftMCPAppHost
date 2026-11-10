# Getting started

Show an MCP App from a tool call in a SwiftUI app.

## Advertise support

MCP servers only return interfaces to clients that say they can show them. Add the MCP Apps capability to your MCP client's `initialize` request:

```swift
let capabilities: MCPJSON = ["extensions": MCPAppProtocol.clientCapability]
```

## Implement the delegate

``MCPAppHostDelegate`` is what the app can ask your host for. Only ``MCPAppHostDelegate/callTool(name:arguments:)`` is required; forward it through your MCP client. Every other request is refused unless you implement it.

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

## Show the app

A tool declares its interface in `_meta.ui.resourceUri`. When the model calls such a tool, read that resource with your client, then create an ``MCPAppWebHost``:

```swift
let resource = try MCPAppResource(readResult: try await client.readResource(uri: uiURI))
let host = MCPAppWebHost(
    resource: resource,
    hostInfo: MCPAppHostInfo(name: "MyApp", version: "1.0"),
    delegate: appHost
)
host.bridge.sendToolInput(arguments)
host.bridge.sendToolResult(callToolResult)
```

You can send the input and result straight away. The bridge holds them until the app has finished its handshake, as the specification requires.

Then put it on screen:

```swift
MCPAppView(host: host, maxHeight: 500)
```

The view sizes itself to the height the app reports. In UIKit, use `MCPAppHostView(host:)`.

## Remove it

Before taking the view off screen, give the app a chance to save its state:

```swift
await host.teardown()
```
