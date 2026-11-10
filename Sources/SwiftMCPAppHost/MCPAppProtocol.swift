import Foundation

/// Constants from the MCP Apps specification (SEP-1865, stable 2026-01-26).
public enum MCPAppProtocol {
    /// The protocol version this host implements.
    public static let latestVersion = "2026-01-26"
    /// Versions this host accepts as requested by an app. Others are answered with ``latestVersion``.
    public static let supportedVersions: Set<String> = [latestVersion]
    /// The extension identifier a client advertises in its MCP `initialize` capabilities.
    public static let extensionID = "io.modelcontextprotocol/ui"
    /// The MIME type every MCP App resource must have.
    public static let resourceMIMEType = "text/html;profile=mcp-app"
    /// The URI scheme every MCP App resource must use.
    public static let resourceScheme = "ui"

    /// The capability value a client adds under `capabilities.extensions` in its MCP `initialize`
    /// request, so servers know it can show MCP Apps.
    public static var clientCapability: MCPJSON {
        .object([extensionID: ["mimeTypes": [.string(resourceMIMEType)]]])
    }

    public enum Method {
        // App → host requests
        public static let initialize = "ui/initialize"
        public static let toolsCall = "tools/call"
        public static let resourcesRead = "resources/read"
        public static let openLink = "ui/open-link"
        public static let message = "ui/message"
        public static let requestDisplayMode = "ui/request-display-mode"
        public static let updateModelContext = "ui/update-model-context"
        public static let ping = "ping"
        // App → host notifications
        public static let initialized = "ui/notifications/initialized"
        public static let sizeChanged = "ui/notifications/size-changed"
        public static let log = "notifications/message"
        public static let requestTeardown = "ui/notifications/request-teardown"
        // Host → app notifications
        public static let toolInputPartial = "ui/notifications/tool-input-partial"
        public static let toolInput = "ui/notifications/tool-input"
        public static let toolResult = "ui/notifications/tool-result"
        public static let toolCancelled = "ui/notifications/tool-cancelled"
        public static let hostContextChanged = "ui/notifications/host-context-changed"
        // Host → app request
        public static let resourceTeardown = "ui/resource-teardown"
    }
}

/// How the app is shown.
public enum MCPAppDisplayMode: String, Sendable, Hashable, Codable, CaseIterable {
    case inline, fullscreen, pip
}

/// A JSON-RPC error returned to the app.
public struct MCPAppError: Error, Sendable, Hashable {
    public var code: Int
    public var message: String
    public var data: MCPJSON?

    public init(code: Int, message: String, data: MCPJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// A refusal, in the form the spec's examples use.
    public static func denied(_ message: String) -> MCPAppError { MCPAppError(code: -32000, message: message) }
    public static let methodNotFound = MCPAppError(code: -32601, message: "Method not found")
    public static func invalidParams(_ message: String) -> MCPAppError { MCPAppError(code: -32602, message: message) }
    public static func internalError(_ message: String) -> MCPAppError { MCPAppError(code: -32603, message: message) }

    var json: MCPJSON {
        var o: [String: MCPJSON] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// One JSON-RPC 2.0 message, in either direction.
public enum MCPAppMessage: Sendable, Hashable {
    case request(id: MCPJSON, method: String, params: MCPJSON?)
    case notification(method: String, params: MCPJSON?)
    case response(id: MCPJSON, result: MCPJSON)
    case errorResponse(id: MCPJSON, error: MCPAppError)

    /// Classifies a decoded JSON value. Returns nil for anything that isn't valid JSON-RPC 2.0.
    public init?(_ json: MCPJSON) {
        guard case .object(let o) = json, o["jsonrpc"] == "2.0" else { return nil }
        let id = o["id"]
        if let id, !Self.isValidID(id) { return nil }
        if let method = o["method"]?.stringValue {
            let params = o["params"]
            if let params, params.objectValue == nil, params.arrayValue == nil { return nil }
            if let id { self = .request(id: id, method: method, params: params) }
            else { self = .notification(method: method, params: params) }
        } else if let id, let result = o["result"] {
            self = .response(id: id, result: result)
        } else if let id, let error = o["error"]?.objectValue,
                  let code = error["code"]?.doubleValue, let message = error["message"]?.stringValue {
            self = .errorResponse(id: id, error: MCPAppError(code: Int(code), message: message, data: error["data"]))
        } else {
            return nil
        }
    }

    static func isValidID(_ id: MCPJSON) -> Bool {
        switch id {
        case .string, .number, .null: true
        default: false
        }
    }

    public var json: MCPJSON {
        switch self {
        case .request(let id, let method, let params):
            var o: [String: MCPJSON] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .notification(let method, let params):
            var o: [String: MCPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { o["params"] = params }
            return .object(o)
        case .response(let id, let result):
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case .errorResponse(let id, let error):
            return ["jsonrpc": "2.0", "id": id, "error": error.json]
        }
    }
}

/// Who the host is, sent to the app in the `ui/initialize` reply.
public struct MCPAppHostInfo: Sendable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    var json: MCPJSON { ["name": .string(name), "version": .string(version)] }
}

/// The host's environment, sent to the app at start and, when it changes, as a partial update.
///
/// Every field is optional; only the ones you set are sent. `extra` carries fields this type
/// doesn't model yet.
public struct MCPAppHostContext: Sendable, Hashable {
    public enum Theme: String, Sendable, Hashable { case light, dark }
    public enum Platform: String, Sendable, Hashable { case web, desktop, mobile }

    public var theme: Theme?
    public var displayMode: MCPAppDisplayMode?
    public var availableDisplayModes: [MCPAppDisplayMode]?
    /// `{"width": …, "maxHeight": …}` and similar, in points.
    public var containerDimensions: MCPJSON?
    public var locale: String?
    public var timeZone: String?
    public var platform: Platform?
    public var deviceCapabilities: MCPJSON?
    public var safeAreaInsets: MCPJSON?
    public var styles: MCPJSON?
    /// The tool call that produced this app: `{"id": …, "tool": {…}}`.
    public var toolInfo: MCPJSON?
    public var extra: [String: MCPJSON]

    public init(
        theme: Theme? = nil, displayMode: MCPAppDisplayMode? = .inline, availableDisplayModes: [MCPAppDisplayMode]? = [.inline],
        containerDimensions: MCPJSON? = nil, locale: String? = nil, timeZone: String? = nil, platform: Platform? = .mobile,
        deviceCapabilities: MCPJSON? = ["touch": true, "hover": false], safeAreaInsets: MCPJSON? = nil, styles: MCPJSON? = nil,
        toolInfo: MCPJSON? = nil, extra: [String: MCPJSON] = [:]
    ) {
        self.theme = theme
        self.displayMode = displayMode
        self.availableDisplayModes = availableDisplayModes
        self.containerDimensions = containerDimensions
        self.locale = locale
        self.timeZone = timeZone
        self.platform = platform
        self.deviceCapabilities = deviceCapabilities
        self.safeAreaInsets = safeAreaInsets
        self.styles = styles
        self.toolInfo = toolInfo
        self.extra = extra
    }

    /// A context for the current device: locale, time zone, mobile platform, touch.
    public static func current(theme: Theme? = nil) -> MCPAppHostContext {
        MCPAppHostContext(theme: theme, locale: Locale.current.identifier(.bcp47), timeZone: TimeZone.current.identifier)
    }

    public var json: [String: MCPJSON] {
        var o = extra
        if let theme { o["theme"] = .string(theme.rawValue) }
        if let displayMode { o["displayMode"] = .string(displayMode.rawValue) }
        if let availableDisplayModes { o["availableDisplayModes"] = .array(availableDisplayModes.map { .string($0.rawValue) }) }
        if let containerDimensions { o["containerDimensions"] = containerDimensions }
        if let locale { o["locale"] = .string(locale) }
        if let timeZone { o["timeZone"] = .string(timeZone) }
        if let platform { o["platform"] = .string(platform.rawValue) }
        if let deviceCapabilities { o["deviceCapabilities"] = deviceCapabilities }
        if let safeAreaInsets { o["safeAreaInsets"] = safeAreaInsets }
        if let styles { o["styles"] = styles }
        if let toolInfo { o["toolInfo"] = toolInfo }
        return o
    }

    /// The keys whose values differ from `old`, including removed keys (sent as null).
    func changes(since old: MCPAppHostContext) -> [String: MCPJSON] {
        let new = json, previous = old.json
        var diff: [String: MCPJSON] = [:]
        for (key, value) in new where previous[key] != value { diff[key] = value }
        for key in previous.keys where new[key] == nil { diff[key] = .null }
        return diff
    }
}
