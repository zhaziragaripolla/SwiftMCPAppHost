import Foundation
import Testing
@testable import SwiftMCPAppHost

// MARK: - Helpers

@MainActor
final class FakeDelegate: MCPAppHostDelegate {
    var toolCalls: [(String, MCPJSON?)] = []
    var toolResult: MCPJSON = ["content": [["type": "text", "text": "ok"]]]
    var toolError: (any Error)?
    var allowLinks = false
    var openedLinks: [URL] = []
    var messages: [MCPJSON] = []
    var acceptMessages = false
    var modelContexts: [MCPJSON] = []
    var grantMode: MCPAppDisplayMode?
    var logs: [MCPJSON?] = []
    var teardownRequests = 0
    var diagnostics: [MCPAppDiagnostic] = []

    func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON {
        toolCalls.append((name, arguments))
        if let toolError { throw toolError }
        return toolResult
    }
    func openLink(_ url: URL) async -> Bool {
        if allowLinks { openedLinks.append(url) }
        return allowLinks
    }
    func receiveMessage(_ message: MCPJSON) async -> Bool {
        if acceptMessages { messages.append(message) }
        return acceptMessages
    }
    func updateModelContext(_ context: MCPJSON) async { modelContexts.append(context) }
    func requestDisplayMode(_ mode: MCPAppDisplayMode, current: MCPAppDisplayMode) async -> MCPAppDisplayMode { grantMode ?? current }
    func didReceiveLog(_ params: MCPJSON?) { logs.append(params) }
    func appDidRequestTeardown() { teardownRequests += 1 }
    func didReport(_ diagnostic: MCPAppDiagnostic) { diagnostics.append(diagnostic) }
}

/// A bridge wired to a fake app: messages it sends are captured as parsed JSON.
@MainActor
final class Harness {
    let bridge: MCPAppBridge
    let delegate = FakeDelegate()
    var sent: [MCPJSON] = []
    private var nextID = 1

    init(context: MCPAppHostContext = MCPAppHostContext(), options: MCPAppBridge.Options = MCPAppBridge.Options(),
         csp: MCPAppResource.CSP? = nil) {
        bridge = MCPAppBridge(hostInfo: MCPAppHostInfo(name: "TestHost", version: "1.0"), hostContext: context,
                              appliedCSP: csp, options: options)
        bridge.delegate = delegate
        bridge.transport = { [weak self] text in self?.sent.append(MCPJSON.parse(text)!) }
    }

    func send(_ json: MCPJSON) { bridge.receive(json.jsonString()) }

    @discardableResult
    func request(_ method: String, _ params: MCPJSON? = nil) async -> MCPJSON {
        let id = MCPJSON.number(Double(nextID))
        nextID += 1
        var message: [String: MCPJSON] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { message["params"] = params }
        send(.object(message))
        for _ in 0..<200 {
            if let reply = sent.first(where: { $0["id"] == id && $0["method"] == nil }) { return reply }
            await Task.yield()
        }
        Issue.record("No reply to \(method)")
        return nil
    }

    func notify(_ method: String, _ params: MCPJSON? = nil) {
        var message: [String: MCPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        send(.object(message))
    }

    func handshake(modes: [MCPAppDisplayMode] = [.inline]) async {
        await request("ui/initialize", [
            "appInfo": ["name": "TestApp", "version": "0.1"],
            "appCapabilities": ["availableDisplayModes": .array(modes.map { .string($0.rawValue) })],
            "protocolVersion": "2026-01-26",
        ])
        notify("ui/notifications/initialized")
    }

    var notifications: [MCPJSON] { sent.filter { $0["id"] == nil } }
}

// MARK: - Tests

@Suite("Messages")
struct MessageTests {
    @Test func classifiesJSONRPC() {
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": 1, "method": "ping"]) == .request(id: 1, method: "ping", params: nil))
        #expect(MCPAppMessage(["jsonrpc": "2.0", "method": "ui/notifications/initialized", "params": [:]])
            == .notification(method: "ui/notifications/initialized", params: [:]))
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": "a", "result": [:]]) == .response(id: "a", result: [:]))
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": 2, "error": ["code": -32000, "message": "no"]])
            == .errorResponse(id: 2, error: MCPAppError(code: -32000, message: "no")))
    }

    @Test func rejectsNonJSONRPC() {
        #expect(MCPAppMessage(["id": 1, "method": "ping"]) == nil)                              // no jsonrpc
        #expect(MCPAppMessage(["jsonrpc": "1.0", "id": 1, "method": "ping"]) == nil)
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": [1], "method": "ping"]) == nil)          // bad id
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": "x"]) == nil)
        #expect(MCPAppMessage(["jsonrpc": "2.0", "id": 1]) == nil)
        #expect(MCPAppMessage("hello") == nil)
    }

    @Test func roundTripsThroughText() {
        let messages: [MCPAppMessage] = [
            .request(id: 7, method: "ui/resource-teardown", params: ["reason": "closed"]),
            .notification(method: "ui/notifications/tool-input", params: ["arguments": ["city": "Lisbon"]]),
            .response(id: "x", result: ["mode": "inline"]),
            .errorResponse(id: 3, error: .methodNotFound),
        ]
        for message in messages {
            #expect(MCPAppMessage(MCPJSON.parse(message.json.jsonString())!) == message)
        }
        #expect(MCPAppMessage.request(id: 7, method: "ping", params: nil).json.jsonString() == #"{"id":7,"jsonrpc":"2.0","method":"ping"}"#)
    }
}

@Suite("Bridge")
@MainActor
struct BridgeTests {
    @Test func handshakeRepliesWithHostDetailsAndGoesReady() async throws {
        let h = Harness(context: MCPAppHostContext(theme: .dark, locale: "en-US"), csp: .init(connectDomains: ["https://api.example.com"]))
        let reply = await h.request("ui/initialize", [
            "appInfo": ["name": "TestApp", "version": "0.1"], "appCapabilities": [:], "protocolVersion": "2026-01-26",
        ])
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == "2026-01-26")
        #expect(result["hostInfo"] == ["name": "TestHost", "version": "1.0"])
        #expect(result["hostContext"]?["theme"] == "dark")
        #expect(result["hostContext"]?["platform"] == "mobile")
        #expect(result["hostCapabilities"]?["sandbox"]?["csp"]?["connectDomains"] == ["https://api.example.com"])
        #expect(h.bridge.state == .awaitingInitialized)
        #expect(h.bridge.appInfo == ["name": "TestApp", "version": "0.1"])
        h.notify("ui/notifications/initialized")
        #expect(h.bridge.state == .ready)
    }

    @Test func unsupportedVersionIsAnsweredWithLatest() async {
        let h = Harness()
        let reply = await h.request("ui/initialize", ["appInfo": [:], "appCapabilities": [:], "protocolVersion": "1999-01-01"])
        #expect(reply["result"]?["protocolVersion"] == .string(MCPAppProtocol.latestVersion))
    }

    @Test func notificationsWaitForInitialized() async {
        let h = Harness()
        h.bridge.sendToolInput(["city": "Lisbon"])
        #expect(h.notifications.isEmpty)
        await h.request("ui/initialize", ["appInfo": [:], "appCapabilities": [:], "protocolVersion": "2026-01-26"])
        h.bridge.sendToolResult(["content": []])
        #expect(h.notifications.isEmpty)      // still not initialized
        h.notify("ui/notifications/initialized")
        #expect(h.notifications.map { $0["method"] } == ["ui/notifications/tool-input", "ui/notifications/tool-result"])
        #expect(h.notifications[0]["params"] == ["arguments": ["city": "Lisbon"]])
        h.bridge.sendToolCancelled(reason: "user")
        #expect(h.notifications.last?["params"] == ["reason": "user"])
    }

    @Test func toolCallRoundTrip() async {
        let h = Harness()
        await h.handshake()
        let reply = await h.request("tools/call", ["name": "report_result", "arguments": ["winner": "X"]])
        #expect(reply["result"] == ["content": [["type": "text", "text": "ok"]]])
        #expect(h.delegate.toolCalls.first?.0 == "report_result")
        #expect(h.delegate.toolCalls.first?.1 == ["winner": "X"])
    }

    @Test func failingToolCallReturnsAnError() async {
        let h = Harness()
        await h.handshake()
        h.delegate.toolError = MCPAppError.denied("Not allowed")
        #expect(await h.request("tools/call", ["name": "x"])["error"]?["code"] == -32000)
        h.delegate.toolError = CocoaError(.fileNoSuchFile)
        let generic = await h.request("tools/call", ["name": "x"])
        #expect(generic["error"]?["code"] == -32603)
        #expect(generic["error"]?["message"] == "Request failed")   // no internal details leak to the app
        #expect(await h.request("tools/call", ["arguments": [:]])["error"]?["code"] == -32602)
    }

    @Test func linksAreRefusedByDefaultAndValidated() async {
        let h = Harness()
        await h.handshake()
        let refused = await h.request("ui/open-link", ["url": "https://example.com"])
        #expect(refused["error"] == ["code": -32000, "message": "Link opening denied by user"])
        h.delegate.allowLinks = true
        #expect(await h.request("ui/open-link", ["url": "https://example.com/a"])["result"] == [:])
        #expect(h.delegate.openedLinks == [URL(string: "https://example.com/a")!])
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "https://", "not a url"] {
            #expect(await h.request("ui/open-link", ["url": .string(bad)])["error"]?["message"] == "Invalid URL")
        }
        #expect(h.delegate.openedLinks.count == 1)
    }

    @Test func messagesAndModelContext() async {
        let h = Harness()
        await h.handshake()
        let message: MCPJSON = ["role": "user", "content": ["type": "text", "text": "I won"]]
        #expect(await h.request("ui/message", message)["error"]?["message"] == "Message sending denied")
        h.delegate.acceptMessages = true
        #expect(await h.request("ui/message", message)["result"] == [:])
        #expect(h.delegate.messages == [message])
        #expect(await h.request("ui/update-model-context", ["structuredContent": ["score": 3]])["result"] == [:])
        #expect(h.delegate.modelContexts == [["structuredContent": ["score": 3]]])
    }

    @Test func displayModeNeedsAppHostAndDelegate() async {
        let h = Harness(context: MCPAppHostContext(availableDisplayModes: [.inline, .fullscreen]))
        await h.handshake(modes: [.inline, .fullscreen])
        #expect(await h.request("ui/request-display-mode", ["mode": "fullscreen"])["result"] == ["mode": "inline"]) // delegate keeps current
        h.delegate.grantMode = .fullscreen
        #expect(await h.request("ui/request-display-mode", ["mode": "fullscreen"])["result"] == ["mode": "fullscreen"])
        #expect(h.bridge.displayMode == .fullscreen)
        #expect(await h.request("ui/request-display-mode", ["mode": "pip"])["result"] == ["mode": "fullscreen"]) // not available
        #expect(await h.request("ui/request-display-mode", ["mode": "huge"])["error"]?["code"] == -32602)
    }

    @Test func unknownMethodsAndMalformedInput() async {
        let h = Harness()
        await h.handshake()
        #expect(await h.request("ui/download-file", [:])["error"] == ["code": -32601, "message": "Method not found"])
        #expect(await h.request("ping")["result"] == [:])
        h.notify("ui/notifications/something-new")
        h.bridge.receive("{not json")
        h.bridge.receive(#"{"jsonrpc":"2.0"}"#)
        h.send(["jsonrpc": "2.0", "id": 99, "result": [:]])   // response to nothing
        #expect(h.delegate.diagnostics.contains(.unknownRequest(method: "ui/download-file")))
        #expect(h.delegate.diagnostics.contains(.unknownNotification(method: "ui/notifications/something-new")))
        #expect(h.delegate.diagnostics.contains(.invalidJSON))
        #expect(h.delegate.diagnostics.contains(.notJSONRPC))
        #expect(h.delegate.diagnostics.contains(.unexpectedResponse(id: 99)))
    }

    @Test func oversizedMessagesAreDropped() async {
        var options = MCPAppBridge.Options()
        options.maxMessageBytes = 100
        let h = Harness(options: options)
        h.send(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": ["pad": .string(String(repeating: "x", count: 200))]])
        for _ in 0..<20 { await Task.yield() }
        #expect(h.sent.isEmpty)
        #expect(h.delegate.diagnostics.contains { if case .messageTooLarge = $0 { true } else { false } })
    }

    @Test func requestsBeforeInitializeAreReportedButAnswered() async {
        let h = Harness()
        #expect(await h.request("tools/call", ["name": "x"])["result"] != nil)
        #expect(h.delegate.diagnostics.contains(.requestBeforeInitialize(method: "tools/call")))
        await h.handshake()
        await h.request("ui/initialize", ["appInfo": [:], "appCapabilities": [:], "protocolVersion": "2026-01-26"])
        #expect(h.delegate.diagnostics.contains(.duplicateInitialize))
    }

    @Test func appNotificationsReachTheHost() async {
        let h = Harness()
        var sizes: [Double?] = []
        h.bridge.onSizeChange = { _, height in sizes.append(height) }
        await h.handshake()
        h.notify("ui/notifications/size-changed", ["width": 320, "height": 412])
        h.notify("notifications/message", ["level": "info", "data": "hi"])
        h.notify("ui/notifications/request-teardown")
        #expect(sizes == [412])
        #expect(h.delegate.logs == [["level": "info", "data": "hi"]])
        #expect(h.delegate.teardownRequests == 1)
    }

    @Test func hostContextChangesSendOnlyTheDifference() async {
        let h = Harness(context: MCPAppHostContext(theme: .light, locale: "en-US"))
        await h.handshake()
        h.bridge.setHostContext(MCPAppHostContext(theme: .dark, locale: "en-US"))
        #expect(h.notifications.last == ["jsonrpc": "2.0", "method": "ui/notifications/host-context-changed", "params": ["theme": "dark"]])
        let count = h.notifications.count
        h.bridge.setHostContext(MCPAppHostContext(theme: .dark, locale: "en-US"))
        #expect(h.notifications.count == count)   // nothing changed, nothing sent
    }

    @Test func handshakeTimeoutIsReported() async throws {
        var options = MCPAppBridge.Options()
        options.handshakeTimeout = .milliseconds(30)
        let h = Harness(options: options)
        h.bridge.start()
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.delegate.diagnostics.contains(.handshakeTimedOut))
    }

    @Test func handshakeInTimeIsNotReported() async throws {
        var options = MCPAppBridge.Options()
        options.handshakeTimeout = .milliseconds(60)
        let h = Harness(options: options)
        h.bridge.start()
        await h.handshake()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!h.delegate.diagnostics.contains(.handshakeTimedOut))
    }

    @Test func teardownWaitsForTheAppsAnswer() async throws {
        let h = Harness()
        await h.handshake()
        let done = Task { await h.bridge.teardown(reason: "closed") }
        for _ in 0..<50 { await Task.yield() }
        let request = try #require(h.sent.last)
        #expect(request["method"] == "ui/resource-teardown")
        #expect(request["params"] == ["reason": "closed"])
        #expect(h.bridge.state == .ready)
        h.send(["jsonrpc": "2.0", "id": request["id"]!, "result": [:]])
        await done.value
        #expect(h.bridge.state == .tornDown)
        h.bridge.sendToolResult([:])
        #expect(h.sent.last == request)       // nothing sent after teardown
    }

    @Test func teardownTimesOutOnASilentApp() async {
        var options = MCPAppBridge.Options()
        options.requestTimeout = .milliseconds(30)
        let h = Harness(options: options)
        await h.handshake()
        await h.bridge.teardown()
        #expect(h.bridge.state == .tornDown)
        #expect(h.delegate.diagnostics.contains(.requestTimedOut(method: "ui/resource-teardown")))
    }

    @Test func teardownBeforeHandshakeSendsNothing() async {
        let h = Harness()
        await h.bridge.teardown()
        #expect(h.sent.isEmpty)
        #expect(h.bridge.state == .tornDown)
    }
}
