# Security

How an MCP App is isolated from your app and the user's data.

## Overview

An MCP App's HTML comes from a third-party server. ``MCPAppWebHost`` treats it as untrusted and applies every control below by default. ``MCPAppSandbox`` exposes the resulting values so they can be inspected and tested.

## Content Security Policy

The policy is built from the resource's declared `_meta.ui.csp` domains, following the specification, and inserted as the document's first element. When the resource declares none, the specification's default applies: inline scripts and styles, `data:` images and media, and no network access.

Declared domains must be plain `https://` or `wss://` origins, optionally with a leading `*.` and a port. Anything else, such as a value carrying extra directives, is dropped and reported through ``MCPAppHostDelegate/didReport(_:)``.

## Network rules

A WebKit content rule list blocks every `http`, `https`, `ws`, `wss`, `ftp` and `file` load, then allows only the declared domains. It applies even if the policy were bypassed.

## Web view settings

- A non-persistent website data store: no cookies, storage or cache survive or are shared between apps.
- No navigation away from the document. Link taps go to ``MCPAppHostDelegate/openLink(_:)``, which refuses by default and only ever receives `http`, `https` or `mailto` URLs.
- No new windows or pop-ups.
- Camera and microphone requests are denied. Declared permissions are reported, never granted.
- No link previews or data detectors.

## The message channel

Only messages from the app's main frame, through one script message handler, that are valid JSON-RPC 2.0 and under the size limit (1 MB by default) are handled. Everything else is dropped and reported. The handshake and host requests have timeouts.

## Your responsibilities

- Don't change `webView`'s configuration or delegates.
- Apply the same permission checks to the app's tool calls as to the model's, and only call tools on the app's own server.
- Confirm with the user before opening links or posting messages, where it matters.
