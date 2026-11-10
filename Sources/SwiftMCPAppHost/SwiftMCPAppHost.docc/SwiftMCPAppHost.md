# ``SwiftMCPAppHost``

Show MCP Apps in a native iOS app.

## Overview

MCP Apps is a Model Context Protocol extension that lets a tool return an interactive HTML interface. SwiftMCPAppHost renders that interface in a sandboxed `WKWebView` and connects it to your app over the MCP Apps JSON-RPC protocol (SEP-1865, version 2026-01-26).

Your app keeps its own MCP client. SwiftMCPAppHost asks it, through ``MCPAppHostDelegate``, to run the tool calls the app makes, and refuses everything else unless you allow it.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Security>
- ``MCPAppWebHost``
- ``MCPAppView``
- ``MCPAppHostDelegate``

### Resources

- ``MCPAppResource``
- ``MCPAppProtocol``

### The protocol

- ``MCPAppBridge``
- ``MCPAppMessage``
- ``MCPAppHostInfo``
- ``MCPAppHostContext``
- ``MCPAppDisplayMode``
- ``MCPAppError``
- ``MCPAppDiagnostic``

### Sandbox

- ``MCPAppSandbox``
- ``MCPAppCSP``

### Values

- ``MCPJSON``
