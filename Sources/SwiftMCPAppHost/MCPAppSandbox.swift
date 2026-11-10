import Foundation

/// The sandbox an MCP App runs in, as plain values: what ``MCPAppWebHost`` builds its web view
/// from. Kept apart from WebKit so every setting can be checked in tests.
public struct MCPAppSandbox: Sendable, Hashable {
    /// The Content Security Policy, inserted as the document's first element.
    public let contentSecurityPolicy: String
    /// Declared domains that failed validation and were left out.
    public let rejectedDomains: [String]
    /// The WebKit content rule list (JSON) that blocks network loads outside the declared domains.
    public let contentRuleList: String
    /// The app's HTML with the policy inserted.
    public let document: String

    // Fixed settings, documented in RFC-001.
    public let persistsWebsiteData = false
    public let allowsOpeningWindows = false
    public let grantsMediaCapture = false
    public let allowsNavigationAwayFromDocument = false
    public let acceptsMessagesFromSubframes = false
    public let allowsLinkPreview = false

    /// The name of the one script message handler the app can reach.
    public static let messageHandlerName = "mcpAppHost"

    public init(resource: MCPAppResource) {
        let (policy, rejected) = MCPAppCSP.policy(for: resource.csp)
        contentSecurityPolicy = policy
        rejectedDomains = rejected
        let csp = resource.csp
        let allowed = [csp?.connectDomains, csp?.resourceDomains, csp?.frameDomains].compactMap { $0 }.flatMap { $0 }
            .filter(MCPAppCSP.isValidSource)
        contentRuleList = Self.ruleList(allowing: allowed)
        document = MCPAppCSP.inject(policy, into: resource.html)
    }

    /// Blocks every network load, then lets declared domains through.
    ///
    /// WebKit's rule regexes have no alternation, so each scheme gets its own rule.
    static func ruleList(allowing domains: [String]) -> String {
        var rules: [MCPJSON] = ["^https?://", "^wss?://", "^ftp://", "^file:"].map { filter in
            ["trigger": ["url-filter": .string(filter)], "action": ["type": "block"]]
        }
        for domain in Set(domains).sorted() {
            guard let filter = urlFilter(for: domain) else { continue }
            rules.append(["trigger": ["url-filter": .string(filter)], "action": ["type": "ignore-previous-rules"]])
        }
        return MCPJSON.array(rules).jsonString()
    }

    /// `https://*.example.com` → `^https://([^/]*\.)?example\.com[:/]`. Nil for invalid sources.
    static func urlFilter(for source: String) -> String? {
        guard MCPAppCSP.isValidSource(source), let split = source.range(of: "://") else { return nil }
        let scheme = String(source[..<split.lowerBound])
        var host = String(source[split.upperBound...])
        var prefix = ""
        if host.hasPrefix("*.") {
            host.removeFirst(2)
            prefix = "([^/]*\\.)?"
        }
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        let terminator = host.contains(":") ? "/" : "[:/]"
        return "^\(scheme)://\(prefix)\(escaped)\(terminator)"
    }

    /// Runs before any of the app's own code.
    ///
    /// At the top level of a web view `window.parent === window`, so an app's
    /// `window.parent.postMessage(…)` would post to itself. This sends those messages to the host
    /// instead, and gives the host one way to deliver its messages as `message` events whose
    /// `source` is `window` (which equals `window.parent` here).
    public static let bridgeScript = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName);
      if (!handler) { return; }
      Object.defineProperty(window, "postMessage", {
        value: function (message) {
          try { handler.postMessage(JSON.stringify(message)); } catch (e) {}
        },
        writable: false, configurable: false
      });
      Object.defineProperty(window, "__mcpAppHostDeliver", {
        value: function (text) {
          let data;
          try { data = JSON.parse(text); } catch (e) { return; }
          window.dispatchEvent(new MessageEvent("message", { data: data, origin: window.location.origin, source: window }));
        },
        writable: false, configurable: false
      });
    })();
    """

    /// A stable identifier for compiling the rule list.
    var ruleListIdentifier: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in contentRuleList.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return "mcp-app-" + String(hash, radix: 16)
    }
}
