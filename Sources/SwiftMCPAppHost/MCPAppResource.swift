import Foundation

/// An MCP App's HTML and its declared security metadata, read from a `ui://` resource.
public struct MCPAppResource: Sendable, Hashable {
    /// Domains the app declares in `_meta.ui.csp`. Each list is validated before use.
    public struct CSP: Sendable, Hashable {
        public var connectDomains: [String]
        public var resourceDomains: [String]
        public var frameDomains: [String]
        public var baseUriDomains: [String]

        public init(connectDomains: [String] = [], resourceDomains: [String] = [],
                    frameDomains: [String] = [], baseUriDomains: [String] = []) {
            self.connectDomains = connectDomains
            self.resourceDomains = resourceDomains
            self.frameDomains = frameDomains
            self.baseUriDomains = baseUriDomains
        }
    }

    /// Device features the app asks for in `_meta.ui.permissions`. This host grants none of them.
    public struct Permissions: Sendable, Hashable {
        public var camera = false
        public var microphone = false
        public var geolocation = false
        public var clipboardWrite = false
        public init() {}
    }

    public enum ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        case noContents
        case wrongMIMEType(String?)
        case notUIScheme(String)
        case noHTML
        case invalidBase64
        case tooLarge(bytes: Int, limit: Int)

        public var description: String {
            switch self {
            case .noContents: "The resource has no contents"
            case .wrongMIMEType(let m): "Expected \(MCPAppProtocol.resourceMIMEType), got \(m ?? "none")"
            case .notUIScheme(let u): "Resource URI must start with ui://, got \(u)"
            case .noHTML: "The resource has neither text nor blob"
            case .invalidBase64: "The resource blob is not valid base64"
            case .tooLarge(let n, let limit): "The HTML is \(n) bytes, over the \(limit)-byte limit"
            }
        }
    }

    public var uri: String
    public var html: String
    /// Nil when the resource declares no CSP: the spec's restrictive default applies.
    public var csp: CSP?
    public var permissions: Permissions
    /// The app's preference for a border. Nil means the host decides.
    public var prefersBorder: Bool?

    public init(uri: String, html: String, csp: CSP? = nil, permissions: Permissions = Permissions(), prefersBorder: Bool? = nil) {
        self.uri = uri
        self.html = html
        self.csp = csp
        self.permissions = permissions
        self.prefersBorder = prefersBorder
    }

    /// The default size limit for an app's HTML: 5 MB.
    public static let defaultMaxBytes = 5 << 20

    /// Parses the result of a `resources/read` call for a `ui://` resource.
    public init(readResult: MCPJSON, maxBytes: Int = MCPAppResource.defaultMaxBytes) throws(ParseError) {
        guard let first = readResult["contents"]?.arrayValue?.first else { throw .noContents }
        try self.init(content: first, maxBytes: maxBytes)
    }

    /// Parses one entry of a `resources/read` result's `contents`.
    public init(content: MCPJSON, maxBytes: Int = MCPAppResource.defaultMaxBytes) throws(ParseError) {
        let uri = content["uri"]?.stringValue ?? ""
        guard uri.lowercased().hasPrefix(MCPAppProtocol.resourceScheme + "://") else { throw .notUIScheme(uri) }
        let mime = content["mimeType"]?.stringValue
        guard let mime, Self.normalizedMIME(mime) == Self.normalizedMIME(MCPAppProtocol.resourceMIMEType) else {
            throw .wrongMIMEType(mime)
        }
        let html: String
        if let text = content["text"]?.stringValue {
            html = text
        } else if let blob = content["blob"]?.stringValue {
            guard let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) else { throw .invalidBase64 }
            html = String(decoding: data, as: UTF8.self)
        } else {
            throw .noHTML
        }
        let bytes = html.utf8.count
        guard bytes <= maxBytes else { throw .tooLarge(bytes: bytes, limit: maxBytes) }

        let ui = content["_meta"]?["ui"]
        var csp: CSP?
        if let c = ui?["csp"]?.objectValue {
            func list(_ key: String) -> [String] { (c[key]?.arrayValue ?? []).compactMap(\.stringValue) }
            csp = CSP(connectDomains: list("connectDomains"), resourceDomains: list("resourceDomains"),
                      frameDomains: list("frameDomains"), baseUriDomains: list("baseUriDomains"))
        }
        var permissions = Permissions()
        if let p = ui?["permissions"]?.objectValue {
            permissions.camera = p["camera"] != nil
            permissions.microphone = p["microphone"] != nil
            permissions.geolocation = p["geolocation"] != nil
            permissions.clipboardWrite = p["clipboardWrite"] != nil
        }
        self.init(uri: uri, html: html, csp: csp, permissions: permissions, prefersBorder: ui?["prefersBorder"]?.boolValue)
    }

    static func normalizedMIME(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

/// Builds the Content Security Policy for an app, following the spec.
public enum MCPAppCSP {
    /// The policy text. With no declared CSP, the spec's restrictive default.
    ///
    /// Domains that fail ``isValidSource(_:)`` are dropped and returned in `rejected`.
    public static func policy(for csp: MCPAppResource.CSP?) -> (policy: String, rejected: [String]) {
        guard let csp else {
            return ("default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                + "img-src 'self' data:; media-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'self'", [])
        }
        var rejected: [String] = []
        func valid(_ list: [String]) -> [String] {
            list.filter { domain in
                if isValidSource(domain) { return true }
                rejected.append(domain)
                return false
            }
        }
        let resources = valid(csp.resourceDomains), connect = valid(csp.connectDomains)
        let frames = valid(csp.frameDomains), bases = valid(csp.baseUriDomains)
        func join(_ base: [String], _ extra: [String]) -> String { (base + extra).joined(separator: " ") }
        let directives = [
            "default-src 'none'",
            "script-src " + join(["'self'", "'unsafe-inline'"], resources),
            "style-src " + join(["'self'", "'unsafe-inline'"], resources),
            "connect-src " + join(["'self'"], connect),
            "img-src " + join(["'self'", "data:"], resources),
            "font-src " + join(["'self'"], resources),
            "media-src " + join(["'self'", "data:"], resources),
            "frame-src " + (frames.isEmpty ? "'none'" : frames.joined(separator: " ")),
            "object-src 'none'",
            "base-uri " + (bases.isEmpty ? "'self'" : bases.joined(separator: " ")),
        ]
        return (directives.joined(separator: "; "), rejected)
    }

    /// Whether a declared domain is safe to put in a policy: an `https://` or `wss://` origin,
    /// optionally with a leading `*.` wildcard and a port, and nothing else.
    public static func isValidSource(_ source: String) -> Bool {
        let pattern = #"^(https|wss)://(\*\.)?([a-z0-9-]+\.)*[a-z0-9-]+(:[0-9]{1,5})?$"#
        return source.count <= 253 && source.lowercased() == source
            && source.range(of: pattern, options: .regularExpression) != nil
    }

    /// The HTML with the policy inserted as the first element, so it applies before any of the
    /// app's own content is parsed.
    static func inject(_ policy: String, into html: String) -> String {
        let escaped = policy.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escaped)\">\n" + html
    }
}
