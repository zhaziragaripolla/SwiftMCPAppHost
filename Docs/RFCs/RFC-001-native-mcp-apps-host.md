# RFC-001: A Native Swift Host for MCP Apps

| | |
|---|---|
| **Status** | Implemented in the first preview |
| **Module** | `SwiftMCPAppHost` |
| **Spec** | MCP Apps (SEP-1865), stable version `2026-01-26`, extension id `io.modelcontextprotocol/ui` |

## TL;DR

**Show each MCP App in its own `WKWebView`, locked down by default, and connect it to the host app through the MCP Apps JSON-RPC protocol, implemented as a pure Swift state machine.** The web view is the native equivalent of the spec's sandboxed iframe. A small script injected before the app's own code routes the app's `window.parent.postMessage` calls to the host and delivers the host's messages back as `message` events, so apps written for web hosts run unchanged. The host app provides tool calls, links and conversation messages through a delegate; this package is not an MCP client. We rejected running the official JavaScript `AppBridge` inside a hidden web view (two JavaScript runtimes to secure, and no Swift API) and hand-rolling a UI per app (that's not MCP Apps).

## Problem

- MCP Apps lets a tool return an interactive HTML interface. The host renders it in a sandbox and talks to it over JSON-RPC.
- The official host (`AppBridge` in `@modelcontextprotocol/ext-apps`) is TypeScript and assumes a browser `<iframe>`. A third-party React Native host exists. There is no Swift host.
- A native iOS app that wants MCP Apps today must build the web view sandbox, the message bridge, the CSP and the lifecycle itself, and get the security right.

## What the spec requires of a host (2026-01-26)

**Resources.** A tool declares its UI with `_meta.ui.resourceUri` (a `ui://` URI). The resource's MIME type must be `text/html;profile=mcp-app`, with the HTML in `text` or base64 `blob`. The resource's `_meta.ui` may carry `csp` (`connectDomains`, `resourceDomains`, `frameDomains`, `baseUriDomains`), `permissions` (`camera`, `microphone`, `geolocation`, `clipboardWrite`), `domain` and `prefersBorder`.

**Channel.** JSON-RPC 2.0 over `postMessage`. The app is the client; the host answers.

**Lifecycle.**
1. The host renders the app.
2. The app sends the request `ui/initialize` with `appInfo`, `appCapabilities` and `protocolVersion`.
3. The host replies with `protocolVersion`, `hostInfo`, `hostCapabilities` and `hostContext`. It echoes the requested version if supported, and otherwise answers with `2026-01-26`, as the official `AppBridge` does.
4. The app sends the notification `ui/notifications/initialized`. **The host must not send anything before this.**
5. The host sends `ui/notifications/tool-input-partial` (0 or more), then `ui/notifications/tool-input` (at most once), then `ui/notifications/tool-result` or `ui/notifications/tool-cancelled`.
6. Before removing the app, the host sends the request `ui/resource-teardown` and should wait for the reply.

**Host → app.** Notifications: `ui/notifications/tool-input-partial`, `ui/notifications/tool-input`, `ui/notifications/tool-result`, `ui/notifications/tool-cancelled`, `ui/notifications/host-context-changed`. Request: `ui/resource-teardown`.

**App → host.** Requests: `ui/initialize`, `tools/call`, `resources/read`, `ui/open-link`, `ui/message`, `ui/request-display-mode`, `ui/update-model-context`, `ping`. Notifications: `ui/notifications/initialized`, `ui/notifications/size-changed`, `notifications/message`, and (SDK only, not in the stable spec) `ui/notifications/request-teardown`.

**Errors.** The spec's examples use `-32000` for refusals ("Link opening denied by user", "Message sending denied"). For unknown methods we answer `-32601` (method not found); the official bridge inherits this from the MCP SDK, which we did not verify.

## Options & Trade-off Matrix

| Criterion | A. Run the official JS `AppBridge` in a hidden web view | B. Bespoke native UI per app | **C. Native state machine + one locked-down web view per app (chosen)** |
|---|---|---|---|
| **Runs existing MCP Apps unchanged** | Yes | No | **Yes**, through a small injected shim |
| **Swift API** | A JS bridge to a JS bridge | n/a | **Native delegate and views** |
| **Testable without WebKit** | No | n/a | **Yes**: the protocol is plain values |
| **Security surface** | Two web contexts to secure | Small | **One web view, deny by default** |
| **Dependencies** | The JS SDK, bundled | None | **None** |

## Design

```
MCP client (yours) ⇄ MCPAppHostDelegate ⇄ MCPAppBridge ⇄ MCPAppWebHost (WKWebView + shim) ⇄ the app's HTML
                                         pure Swift       WebKit
```

**`MCPJSON`.** A small `Sendable`, `Hashable`, `Codable` JSON enum. JSON-RPC ids are echoed exactly as received.

**`MCPAppBridge`** (`@MainActor`). A state machine: `awaitingInitialize → awaitingInitialized → ready → tornDown`.
- Incoming text is size-checked, decoded, and classified as a request, notification or response. Anything else is dropped with a diagnostic.
- Requests are routed to the delegate and answered with a result or a JSON-RPC error. Unknown requests get `-32601`.
- Host → app notifications sent before `ui/notifications/initialized` are queued and flushed when it arrives, which satisfies the spec's "must not send before initialized" rule without burdening the caller.
- If `ui/notifications/initialized` doesn't arrive within the handshake timeout (default 15 s, the figure Claude uses), the bridge reports it.
- Outgoing requests (`ui/resource-teardown`) have a timeout and are failed on teardown.
- Host context changes are diffed, and only changed keys are sent, like the official `AppBridge`.

**`MCPAppHostDelegate`.** What the host app provides: `callTool`, `readResource`, `openLink`, `receiveMessage`, `updateModelContext`, `requestDisplayMode`, `didReceiveLog`, `appDidRequestTeardown`, `didReport(diagnostic)`. All but `callTool` have default implementations; the defaults refuse rather than allow (links aren't opened, messages aren't accepted, resources aren't read).

**`MCPAppResource`.** Parses a `resources/read` result: checks the MIME type and the `ui://` scheme, decodes `text` or base64 `blob`, caps the size, and reads `_meta.ui`.

**`MCPAppWebHost`** owns the `WKWebView` and applies the sandbox. **`MCPAppView`** (SwiftUI) and **`MCPAppHostView`** (UIKit) wrap it and size themselves from `ui/notifications/size-changed`.

### The shim

Native hosts render the app directly, with no sandbox proxy (the spec's double iframe is for web hosts). At the top level of a web view, `window.parent === window`, so an app's `window.parent.postMessage(…)` would post to itself. Before any of the app's code runs, an injected script:

- replaces `window.postMessage` so the app's messages go to the host's script message handler instead of being dispatched locally, and
- exposes one function the host calls to deliver its messages as `message` events whose `source` is `window` (which equals `window.parent` at the top level, so apps that check the source accept them).

Host messages are delivered with `callAsyncJavaScript` and passed as an argument, never spliced into source code.

### The sandbox

The app's HTML is untrusted content from a third party. Every control below is on by default.

| Control | How | What it prevents |
|---|---|---|
| Content Security Policy | A `<meta http-equiv>` policy inserted as the first element of the document, built from `_meta.ui.csp` exactly as the spec describes; the spec's restrictive default when none is declared | Loading scripts, styles, images, media, fonts or frames from undeclared origins; network access (`connect-src 'none'` by default) |
| Domain validation | Declared domains must be `https://` or `wss://` origins with an optional leading `*.` wildcard and no paths, quotes, spaces or semicolons; others are dropped and reported | Injecting extra CSP directives through a crafted domain |
| Content rule list | A `WKContentRuleList` that blocks all `http(s)`/`ws(s)` loads except declared domains | Network access even if the CSP were bypassed |
| Non-persistent data store | `WKWebsiteDataStore.nonPersistent()` for every app | Cookies, storage and cache surviving or being shared between apps |
| Navigation policy | Only the initial document load is allowed; link activations go to `openLink` and are cancelled | The app navigating itself or the web view elsewhere |
| No new windows | `javaScriptCanOpenWindowsAutomatically = false`, and `createWebViewWith` returns `nil` | Pop-ups and new windows |
| Media capture | `requestMediaCapturePermissionFor` always denies | Camera and microphone. Declared `permissions` are reported as not granted, as Claude's mobile apps do |
| One message channel | Only the named script message handler, only from the main frame, only valid JSON-RPC | Messages from sub-frames or arbitrary scripts being treated as protocol |
| Size limits | 5 MB HTML, 1 MB per message (configurable) | Memory exhaustion |
| Timeouts | Handshake and outgoing requests | Waiting forever on a hung app |
| One web view per app | Each `MCPAppWebHost` builds its own configuration and data store | One app reaching another's content |

Geolocation and clipboard writes are not granted either. Inline content can't steal vertical scrolling, because the web view's own scrolling is disabled and the host sizes it to the content.

## Risks & Open Questions

- **Compatibility with the official SDK.** Verified with `@modelcontextprotocol/ext-apps` 2.0.4: its `PostMessageTransport` posts to `window.parent` and accepts messages whose `source` is `window.parent`, which the shim provides, and its schema validation accepts this host's `ui/initialize` reply. Every request type and teardown worked in the example app.
- **Overriding `window.postMessage`** breaks apps that post messages to themselves. We judge this rare; it's documented.
- **Apps that check `event.origin`.** We set `origin` to the document's origin. An app that requires a specific host origin would need it configured; none of the spec's examples do.
- **`-32601` for unknown methods** follows JSON-RPC; the reference bridge's exact behavior comes from the MCP SDK, which we didn't verify.
- **Permissions.** We grant none, which is safe and spec-compliant (apps must feature-detect). Granting camera or microphone on request could come later, behind an explicit host opt-in.
- **`ui/download-file`, `sampling/createMessage`** and other SDK-only methods aren't in the stable spec and get `-32601`.
- **Spec drift.** The draft spec may change messages. The version is a single constant, and unknown fields are preserved, not rejected.

## Success Metrics

- Every message in the stable spec encodes and decodes, with tests.
- The handshake, a tool call round trip, refusals, malformed input, oversized input, unknown methods and timeouts are covered by tests that run without WebKit.
- A real HTML app written against `window.parent.postMessage` runs unchanged in the example app on iOS, and one tool call reaches the host.
- Zero dependencies.
