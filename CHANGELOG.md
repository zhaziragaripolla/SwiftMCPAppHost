# Changelog

## [Unreleased]

### Added
- `MCPAppWebHost`, `MCPAppView` (SwiftUI) and `MCPAppHostView` (UIKit): show an MCP App in a sandboxed `WKWebView`.
- `MCPAppBridge`: the MCP Apps protocol (SEP-1865, 2026-01-26) as a state machine: the `ui/initialize` handshake, tool input and results, `tools/call`, `resources/read`, `ui/open-link`, `ui/message`, `ui/update-model-context`, `ui/request-display-mode`, size changes, logging and teardown.
- `MCPAppHostDelegate`: what the host app provides; everything but `callTool` refuses by default.
- `MCPAppResource`: parses `ui://` resources and their `_meta.ui` metadata.
- `MCPAppCSP` and `MCPAppSandbox`: the Content Security Policy, network rules and web view settings.
- RFC-001, the TicTacToe example, `llms.txt`, `llms-full.txt`, DocC articles and a Claude Code plugin with a skill.
