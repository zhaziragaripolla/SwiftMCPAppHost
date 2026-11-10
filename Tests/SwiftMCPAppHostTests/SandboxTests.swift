import Foundation
import Testing
@testable import SwiftMCPAppHost

@Suite("Resource")
struct ResourceTests {
    @Test func parsesTextResourceWithMetadata() throws {
        let read: MCPJSON = ["contents": [[
            "uri": "ui://game/board", "mimeType": "text/html;profile=mcp-app", "text": "<p>hi</p>",
            "_meta": ["ui": [
                "csp": ["connectDomains": ["https://api.example.com"], "resourceDomains": ["https://*.cdn.example.com"]],
                "permissions": ["camera": [:], "clipboardWrite": [:]],
                "prefersBorder": false,
            ]],
        ]]]
        let resource = try MCPAppResource(readResult: read)
        #expect(resource.uri == "ui://game/board")
        #expect(resource.html == "<p>hi</p>")
        #expect(resource.csp?.connectDomains == ["https://api.example.com"])
        #expect(resource.csp?.resourceDomains == ["https://*.cdn.example.com"])
        #expect(resource.permissions.camera && resource.permissions.clipboardWrite && !resource.permissions.microphone)
        #expect(resource.prefersBorder == false)
    }

    @Test func parsesBase64Blob() throws {
        let blob = Data("<h1>blob</h1>".utf8).base64EncodedString()
        let resource = try MCPAppResource(content: ["uri": "ui://a/b", "mimeType": "text/html; profile=mcp-app", "blob": .string(blob)])
        #expect(resource.html == "<h1>blob</h1>")
        #expect(resource.csp == nil)
    }

    @Test func rejectsBadResources() {
        func error(_ content: MCPJSON, max: Int = 1000) -> MCPAppResource.ParseError? {
            do { _ = try MCPAppResource(content: content, maxBytes: max); return nil } catch { return error }
        }
        #expect(error(["uri": "https://x", "mimeType": "text/html;profile=mcp-app", "text": ""]) == .notUIScheme("https://x"))
        #expect(error(["uri": "ui://a", "mimeType": "text/html", "text": ""]) == .wrongMIMEType("text/html"))
        #expect(error(["uri": "ui://a", "mimeType": "text/html;profile=mcp-app"]) == .noHTML)
        #expect(error(["uri": "ui://a", "mimeType": "text/html;profile=mcp-app", "blob": "%%%"]) == .invalidBase64)
        #expect(error(["uri": "ui://a", "mimeType": "text/html;profile=mcp-app", "text": .string(String(repeating: "x", count: 1001))])
            == .tooLarge(bytes: 1001, limit: 1000))
        #expect((try? MCPAppResource(readResult: ["contents": []])) == nil)
    }
}

@Suite("Sandbox")
struct SandboxTests {
    @Test func defaultPolicyIsTheSpecsRestrictiveOne() {
        let policy = MCPAppCSP.policy(for: nil).policy
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("connect-src 'none'"))
        #expect(policy.contains("img-src 'self' data:"))
        #expect(policy.contains("object-src 'none'"))
    }

    @Test func declaredDomainsExtendThePolicy() {
        let (policy, rejected) = MCPAppCSP.policy(for: .init(
            connectDomains: ["https://api.example.com"], resourceDomains: ["https://*.cdn.example.com"],
            frameDomains: ["https://player.example.com"]))
        #expect(rejected.isEmpty)
        #expect(policy.contains("connect-src 'self' https://api.example.com"))
        #expect(policy.contains("script-src 'self' 'unsafe-inline' https://*.cdn.example.com"))
        #expect(policy.contains("img-src 'self' data: https://*.cdn.example.com"))
        #expect(policy.contains("frame-src https://player.example.com"))
        #expect(policy.contains("base-uri 'self'"))
    }

    @Test func injectionAttemptsAreDropped() {
        let attacks = [
            "https://ok.com; script-src *", "https://a.com 'unsafe-eval'", "*", "http://plain.com",
            "https://a.com/path", "javascript:alert(1)", "https://UPPER.com", "https://*", "data:", "'self'",
        ]
        let (policy, rejected) = MCPAppCSP.policy(for: .init(connectDomains: attacks))
        #expect(Set(rejected) == Set(attacks))
        #expect(policy.contains("connect-src 'self';"))
        #expect(MCPAppCSP.isValidSource("wss://live.example.com:8443"))
        #expect(MCPAppCSP.isValidSource("https://*.example.com"))
    }

    @Test func documentStartsWithThePolicy() {
        let sandbox = MCPAppSandbox(resource: MCPAppResource(uri: "ui://a", html: "<script>evil()</script>"))
        #expect(sandbox.document.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';"))
        #expect(sandbox.document.hasSuffix("<script>evil()</script>"))
    }

    @Test func fixedSettingsDenyByDefault() {
        let sandbox = MCPAppSandbox(resource: MCPAppResource(uri: "ui://a", html: ""))
        #expect(!sandbox.persistsWebsiteData)
        #expect(!sandbox.allowsOpeningWindows)
        #expect(!sandbox.grantsMediaCapture)
        #expect(!sandbox.allowsNavigationAwayFromDocument)
        #expect(!sandbox.acceptsMessagesFromSubframes)
        #expect(!sandbox.allowsLinkPreview)
    }

    @Test func contentRulesBlockEverythingExceptDeclaredDomains() throws {
        let sandbox = MCPAppSandbox(resource: MCPAppResource(uri: "ui://a", html: "", csp: .init(
            connectDomains: ["https://api.example.com"], resourceDomains: ["https://*.cdn.example.com", "bad domain"])))
        let rules = try #require(MCPJSON.parse(sandbox.contentRuleList)?.arrayValue)
        let blocks = rules.filter { $0["action"]?["type"] == "block" }.compactMap { $0["trigger"]?["url-filter"]?.stringValue }
        let allows = rules.filter { $0["action"]?["type"] == "ignore-previous-rules" }.compactMap { $0["trigger"]?["url-filter"]?.stringValue }
        #expect(blocks == ["^https?://", "^wss?://", "^ftp://", "^file:"])
        #expect(Set(allows) == [#"^https://api\.example\.com[:/]"#, #"^https://([^/]*\.)?cdn\.example\.com[:/]"#])
        #expect(sandbox.rejectedDomains == ["bad domain"])
    }

    @Test func noDeclaredDomainsMeansOnlyBlocks() throws {
        let sandbox = MCPAppSandbox(resource: MCPAppResource(uri: "ui://a", html: ""))
        let rules = try #require(MCPJSON.parse(sandbox.contentRuleList)?.arrayValue)
        #expect(rules.allSatisfy { $0["action"]?["type"] == "block" })
    }

    @Test func urlFiltersMatchTheirDomainsOnly() throws {
        let filter = try #require(MCPAppSandbox.urlFilter(for: "https://*.cdn.example.com"))
        func matches(_ url: String) -> Bool { url.range(of: filter, options: .regularExpression) != nil }
        #expect(matches("https://cdn.example.com/a.js"))
        #expect(matches("https://eu.cdn.example.com/a.js"))
        #expect(!matches("https://cdn.example.com.evil.com/a.js"))
        #expect(!matches("https://evilcdn.example.com/a.js"))
        #expect(!matches("http://cdn.example.com/a.js"))
        let port = try #require(MCPAppSandbox.urlFilter(for: "wss://live.example.com:8443"))
        #expect("wss://live.example.com:8443/socket".range(of: port, options: .regularExpression) != nil)
        #expect("wss://live.example.com:9999/socket".range(of: port, options: .regularExpression) == nil)
    }

    @Test func bridgeScriptRoutesToTheNamedHandler() {
        #expect(MCPAppSandbox.bridgeScript.contains("messageHandlers.mcpAppHost"))
        #expect(MCPAppSandbox.bridgeScript.contains("source: window"))
    }

    @Test func clientCapabilityAdvertisesTheMIMEType() {
        #expect(MCPAppProtocol.clientCapability == ["io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]])
    }
}
