import Foundation

/// The MCP Apps protocol between your app and one MCP App, as a state machine.
///
/// It knows nothing about WebKit: it takes message text in with ``receive(_:)`` and hands
/// message text out through ``transport``. ``MCPAppWebHost`` connects it to a web view; tests and
/// other transports can drive it directly.
@MainActor
public final class MCPAppBridge {
    public enum State: Sendable, Hashable {
        /// Waiting for the app's `ui/initialize` request.
        case awaitingInitialize
        /// Replied to `ui/initialize`; waiting for `ui/notifications/initialized`.
        case awaitingInitialized
        /// The handshake is complete. Host notifications are delivered immediately.
        case ready
        /// Torn down. Nothing more is sent or handled.
        case tornDown
    }

    public struct Options: Sendable {
        /// How long the app has to finish the handshake after ``start()``. Claude uses 15 seconds.
        public var handshakeTimeout: Duration = .seconds(15)
        /// How long to wait for the app to answer a request from the host, such as teardown.
        public var requestTimeout: Duration = .seconds(5)
        /// Messages from the app larger than this are dropped.
        public var maxMessageBytes = 1 << 20
        /// Host notifications held while waiting for the handshake, before the oldest are dropped.
        public var maxQueuedNotifications = 1_000
        public init() {}
    }

    public private(set) var state: State = .awaitingInitialize
    /// The app's `appInfo` from `ui/initialize`, e.g. `{"name": …, "version": …}`.
    public private(set) var appInfo: MCPJSON?
    /// The app's `appCapabilities` from `ui/initialize`.
    public private(set) var appCapabilities: MCPJSON?
    /// The protocol version agreed in the handshake.
    public private(set) var protocolVersion: String?
    public private(set) var hostContext: MCPAppHostContext
    public var displayMode: MCPAppDisplayMode { hostContext.displayMode ?? .inline }

    public weak var delegate: (any MCPAppHostDelegate)?
    /// Called with each message for the app, as JSON text. Set by ``MCPAppWebHost``.
    public var transport: (@MainActor (String) -> Void)?
    /// Called when the app reports its content size (`ui/notifications/size-changed`), in points.
    public var onSizeChange: (@MainActor (_ width: Double?, _ height: Double?) -> Void)?
    /// Called when the state changes.
    public var onStateChange: (@MainActor (State) -> Void)?

    public let hostInfo: MCPAppHostInfo
    public let options: Options
    private let hostCapabilities: MCPJSON
    private var queue: [MCPAppMessage] = []
    private var pending: [String: (method: String, continuation: CheckedContinuation<MCPJSON, any Error>)] = [:]
    private var nextRequestID = 1
    private var handshakeTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - hostInfo: Your app's name and version, sent to the app in the handshake.
    ///   - hostContext: Theme, locale, display mode and the rest, sent in the handshake.
    ///   - appliedCSP: The CSP the host actually enforces, reported to the app in `hostCapabilities.sandbox`.
    ///   - capabilities: Overrides the default `hostCapabilities`.
    ///   - options: Timeouts and size limits.
    public init(
        hostInfo: MCPAppHostInfo, hostContext: MCPAppHostContext = .current(), appliedCSP: MCPAppResource.CSP? = nil,
        capabilities: MCPJSON? = nil, options: Options = Options()
    ) {
        self.hostInfo = hostInfo
        self.hostContext = hostContext
        self.options = options
        self.hostCapabilities = capabilities ?? Self.defaultCapabilities(csp: appliedCSP)
    }

    static func defaultCapabilities(csp: MCPAppResource.CSP?) -> MCPJSON {
        var sandbox: [String: MCPJSON] = ["permissions": [:]]
        if let csp {
            sandbox["csp"] = [
                "connectDomains": .array(csp.connectDomains.map(MCPJSON.string)),
                "resourceDomains": .array(csp.resourceDomains.map(MCPJSON.string)),
                "frameDomains": .array(csp.frameDomains.map(MCPJSON.string)),
                "baseUriDomains": .array(csp.baseUriDomains.map(MCPJSON.string)),
            ]
        }
        return [
            "openLinks": [:], "serverTools": [:], "serverResources": [:], "logging": [:],
            "message": [:], "updateModelContext": [:], "sandbox": .object(sandbox),
        ]
    }

    // MARK: Lifecycle

    /// Starts the handshake timer. Call when the app's document starts loading.
    public func start() {
        guard state == .awaitingInitialize, handshakeTimer == nil else { return }
        let timeout = options.handshakeTimeout
        handshakeTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.state != .ready, self.state != .tornDown else { return }
            self.report(.handshakeTimedOut)
        }
    }

    /// Asks the app to clean up (`ui/resource-teardown`) and waits for its answer or the request
    /// timeout, then stops. Safe to call more than once.
    public func teardown(reason: String = "closed") async {
        guard state != .tornDown else { return }
        if state == .ready {
            _ = try? await request(MCPAppProtocol.Method.resourceTeardown, params: ["reason": .string(reason)])
        }
        close()
    }

    /// Stops immediately, without asking the app. Pending requests fail.
    public func close() {
        guard state != .tornDown else { return }
        handshakeTimer?.cancel()
        queue.removeAll()
        let waiting = pending
        pending.removeAll()
        for (_, entry) in waiting { entry.continuation.resume(throwing: MCPAppError.denied("Torn down")) }
        setState(.tornDown)
    }

    // MARK: Host → app

    /// Streams partial tool arguments while the model is still writing them.
    public func sendToolInputPartial(_ arguments: MCPJSON) {
        notify(MCPAppProtocol.Method.toolInputPartial, params: ["arguments": arguments])
    }

    /// Sends the complete tool arguments. Send at most once, before the result.
    public func sendToolInput(_ arguments: MCPJSON) {
        notify(MCPAppProtocol.Method.toolInput, params: ["arguments": arguments])
    }

    /// Sends the tool's `CallToolResult` (`{"content": …, "structuredContent": …}`).
    public func sendToolResult(_ result: MCPJSON) {
        notify(MCPAppProtocol.Method.toolResult, params: result)
    }

    /// Tells the app the tool call was cancelled.
    public func sendToolCancelled(reason: String) {
        notify(MCPAppProtocol.Method.toolCancelled, params: ["reason": .string(reason)])
    }

    /// Updates the host context and sends the app only the fields that changed.
    public func setHostContext(_ context: MCPAppHostContext) {
        let changes = context.changes(since: hostContext)
        hostContext = context
        // Before ui/initialize is answered, the reply itself carries the new context.
        guard !changes.isEmpty, state == .awaitingInitialized || state == .ready else { return }
        notify(MCPAppProtocol.Method.hostContextChanged, params: .object(changes))
    }

    // MARK: App → host

    /// Handles one message from the app, as JSON text.
    public func receive(_ text: String) {
        guard state != .tornDown else { return }
        let bytes = text.utf8.count
        guard bytes <= options.maxMessageBytes else { return report(.messageTooLarge(bytes: bytes, limit: options.maxMessageBytes)) }
        guard let json = MCPJSON.parse(text) else { return report(.invalidJSON) }
        guard let message = MCPAppMessage(json) else { return report(.notJSONRPC) }
        switch message {
        case .request(let id, let method, let params):
            if state == .awaitingInitialize, method != MCPAppProtocol.Method.initialize, method != MCPAppProtocol.Method.ping {
                report(.requestBeforeInitialize(method: method))
            }
            if method == MCPAppProtocol.Method.initialize {
                // Answered synchronously so the handshake order is deterministic.
                send(handleInitialize(id: id, params: params))
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    let reply = await self.handleRequest(id: id, method: method, params: params)
                    if self.state != .tornDown { self.send(reply) }
                }
            }
        case .notification(let method, let params):
            handleNotification(method: method, params: params)
        case .response(let id, let result):
            resolve(id: id, with: .success(result))
        case .errorResponse(let id, let error):
            resolve(id: id, with: .failure(error))
        }
    }

    private func handleInitialize(id: MCPJSON, params: MCPJSON?) -> MCPAppMessage {
        if state != .awaitingInitialize { report(.duplicateInitialize) }
        appInfo = params?["appInfo"]
        appCapabilities = params?["appCapabilities"]
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { MCPAppProtocol.supportedVersions.contains($0) ? $0 : nil } ?? MCPAppProtocol.latestVersion
        protocolVersion = version
        if state == .awaitingInitialize { setState(.awaitingInitialized) }
        return .response(id: id, result: [
            "protocolVersion": .string(version),
            "hostInfo": hostInfo.json,
            "hostCapabilities": hostCapabilities,
            "hostContext": .object(hostContext.json),
        ])
    }

    private func handleRequest(id: MCPJSON, method: String, params: MCPJSON?) async -> MCPAppMessage {
        do {
            return .response(id: id, result: try await result(for: method, params: params))
        } catch let error as MCPAppError {
            return .errorResponse(id: id, error: error)
        } catch {
            return .errorResponse(id: id, error: .internalError("Request failed"))
        }
    }

    private func result(for method: String, params: MCPJSON?) async throws -> MCPJSON {
        typealias M = MCPAppProtocol.Method
        switch method {
        case M.ping:
            return [:]
        case M.toolsCall:
            guard let name = params?["name"]?.stringValue, !name.isEmpty else { throw MCPAppError.invalidParams("Missing tool name") }
            guard let delegate else { throw MCPAppError.internalError("No host delegate") }
            return try await delegate.callTool(name: name, arguments: params?["arguments"])
        case M.resourcesRead:
            guard let uri = params?["uri"]?.stringValue else { throw MCPAppError.invalidParams("Missing uri") }
            guard let delegate else { throw MCPAppError.denied("Resource reading is not available") }
            return try await delegate.readResource(uri: uri)
        case M.openLink:
            guard let text = params?["url"]?.stringValue, let url = Self.openableURL(text) else {
                throw MCPAppError.denied("Invalid URL")
            }
            guard let delegate, await delegate.openLink(url) else { throw MCPAppError.denied("Link opening denied by user") }
            return [:]
        case M.message:
            guard let params, params.objectValue != nil else { throw MCPAppError.invalidParams("Missing message") }
            guard let delegate, await delegate.receiveMessage(params) else { throw MCPAppError.denied("Message sending denied") }
            return [:]
        case M.updateModelContext:
            await delegate?.updateModelContext(params ?? [:])
            return [:]
        case M.requestDisplayMode:
            guard let raw = params?["mode"]?.stringValue, let requested = MCPAppDisplayMode(rawValue: raw) else {
                throw MCPAppError.invalidParams("Unknown display mode")
            }
            let current = displayMode
            var granted = current
            if appAllows(requested), hostContext.availableDisplayModes?.contains(requested) ?? (requested == .inline),
               let delegate {
                granted = await delegate.requestDisplayMode(requested, current: current)
            }
            if granted != current {
                var context = hostContext
                context.displayMode = granted
                hostContext = context
            }
            return ["mode": .string(granted.rawValue)]
        default:
            report(.unknownRequest(method: method))
            throw MCPAppError.methodNotFound
        }
    }

    private func appAllows(_ mode: MCPAppDisplayMode) -> Bool {
        guard let modes = appCapabilities?["availableDisplayModes"]?.arrayValue else { return mode == .inline }
        return modes.contains(.string(mode.rawValue))
    }

    /// Only `http`, `https` and `mailto` links are ever passed to the delegate.
    static func openableURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        default: return nil
        }
    }

    private func handleNotification(method: String, params: MCPJSON?) {
        typealias M = MCPAppProtocol.Method
        switch method {
        case M.initialized:
            guard state == .awaitingInitialized else { return }
            handshakeTimer?.cancel()
            setState(.ready)
            let flushed = queue
            queue.removeAll()
            flushed.forEach(send)
        case M.sizeChanged:
            onSizeChange?(params?["width"]?.doubleValue, params?["height"]?.doubleValue)
        case M.log:
            delegate?.didReceiveLog(params)
        case M.requestTeardown:
            delegate?.appDidRequestTeardown()
        default:
            report(.unknownNotification(method: method))
        }
    }

    // MARK: Sending

    private func notify(_ method: String, params: MCPJSON?) {
        let message = MCPAppMessage.notification(method: method, params: params)
        switch state {
        case .ready:
            send(message)
        case .awaitingInitialize, .awaitingInitialized:
            // The spec forbids sending before the app's initialized notification. Hold it.
            if queue.count >= options.maxQueuedNotifications { queue.removeFirst() }
            queue.append(message)
        case .tornDown:
            break
        }
    }

    private func request(_ method: String, params: MCPJSON?) async throws -> MCPJSON {
        let id = MCPJSON.number(Double(nextRequestID))
        nextRequestID += 1
        let key = id.jsonString()
        let timeout = options.requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = (method, continuation)
            send(.request(id: id, method: method, params: params))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let entry = self.pending.removeValue(forKey: key) else { return }
                self.report(.requestTimedOut(method: entry.method))
                entry.continuation.resume(throwing: MCPAppError.internalError("Timed out"))
            }
        }
    }

    private func resolve(id: MCPJSON, with result: Result<MCPJSON, MCPAppError>) {
        guard let entry = pending.removeValue(forKey: id.jsonString()) else { return report(.unexpectedResponse(id: id)) }
        entry.continuation.resume(with: result.mapError { $0 as any Error })
    }

    private func send(_ message: MCPAppMessage) {
        transport?(message.json.jsonString())
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    func report(_ diagnostic: MCPAppDiagnostic) {
        delegate?.didReport(diagnostic)
    }
}
