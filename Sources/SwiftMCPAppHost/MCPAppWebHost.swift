import Foundation
public import WebKit
public import Observation

/// Shows one MCP App in a locked-down `WKWebView` and connects it to an ``MCPAppBridge``.
///
/// Create one per app. Put it on screen with ``MCPAppView`` (SwiftUI) or ``MCPAppHostView``
/// (UIKit), then drive the app through ``bridge``: send the tool input and result, update the
/// host context, and call ``teardown(reason:)`` before removing it.
@MainActor
@Observable
public final class MCPAppWebHost {
    public let resource: MCPAppResource
    public let sandbox: MCPAppSandbox
    public let bridge: MCPAppBridge
    /// The web view. Its settings are the sandbox; don't change them.
    @ObservationIgnored public let webView: WKWebView
    /// The content height the app last reported, in points. Nil until it reports one.
    public private(set) var contentHeight: Double?

    @ObservationIgnored private let coordinator = Coordinator()
    @ObservationIgnored private var loadStarted = false

    public init(
        resource: MCPAppResource, hostInfo: MCPAppHostInfo, hostContext: MCPAppHostContext = .current(),
        delegate: (any MCPAppHostDelegate)?, options: MCPAppBridge.Options = MCPAppBridge.Options()
    ) {
        let sandbox = MCPAppSandbox(resource: resource)
        self.resource = resource
        self.sandbox = sandbox
        let bridge = MCPAppBridge(hostInfo: hostInfo, hostContext: hostContext, appliedCSP: resource.csp, options: options)
        bridge.delegate = delegate
        self.bridge = bridge
        self.webView = WKWebView(frame: .zero, configuration: Self.configuration(for: sandbox, coordinator: coordinator))
        Self.lockDown(webView)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.host = self

        bridge.transport = { [weak self] text in self?.deliver(text) }
        bridge.onSizeChange = { [weak self] _, height in
            guard let self, let height, height.isFinite, height >= 0 else { return }
            self.contentHeight = min(height, 100_000)
        }
        for domain in sandbox.rejectedDomains { bridge.report(.rejectedCSPDomain(domain)) }
        if resource.permissions.camera { bridge.report(.refusedPermission("camera")) }
        if resource.permissions.microphone { bridge.report(.refusedPermission("microphone")) }
        if resource.permissions.geolocation { bridge.report(.refusedPermission("geolocation")) }
        if resource.permissions.clipboardWrite { bridge.report(.refusedPermission("clipboardWrite")) }
    }

    /// Compiles the network rules and loads the app. Called by the views; safe to call again.
    public func load() {
        guard !loadStarted else { return }
        loadStarted = true
        bridge.start()
        let sandbox = self.sandbox
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: sandbox.ruleListIdentifier, encodedContentRuleList: sandbox.contentRuleList
        ) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self, self.bridge.state != .tornDown else { return }
                guard let list else {
                    // Fail closed: without the network rules, the app isn't shown.
                    self.bridge.report(.blockedNavigation("content rules failed to compile"))
                    return
                }
                self.webView.configuration.userContentController.add(list)
                self.coordinator.allowInitialLoad = true
                self.webView.loadHTMLString(sandbox.document, baseURL: nil)
            }
        }
    }

    /// Asks the app to clean up, then stops it and releases the web view's resources.
    public func teardown(reason: String = "closed") async {
        await bridge.teardown(reason: reason)
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func deliver(_ text: String) {
        webView.callAsyncJavaScript(
            "window.__mcpAppHostDeliver(text)", arguments: ["text": text], in: nil, in: .page, completionHandler: nil)
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return bridge.report(.messageFromSubframe) }
        guard let text = message.body as? String else { return bridge.report(.invalidJSON) }
        bridge.receive(text)
    }

    fileprivate func openLink(_ url: URL) {
        guard let opened = MCPAppBridge.openableURL(url.absoluteString) else {
            return bridge.report(.blockedNavigation(url.absoluteString))
        }
        let delegate = bridge.delegate
        Task { _ = await delegate?.openLink(opened) }
    }

    // MARK: Sandbox

    private static func configuration(for sandbox: MCPAppSandbox, coordinator: Coordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(iOS) || os(visionOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.dataDetectorTypes = []
        #endif
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: MCPAppSandbox.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(coordinator), name: MCPAppSandbox.messageHandlerName)
        config.userContentController = controller
        return config
    }

    private static func lockDown(_ webView: WKWebView) {
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        #if os(iOS) || os(visionOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The host sizes the view to the content, so the conversation keeps vertical scrolling.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
    }
}

// MARK: - WebKit delegates

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var host: MCPAppWebHost?
    var allowInitialLoad = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.received(message)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Sub-frames may load what the CSP and the content rules allow.
        if let target = action.targetFrame, !target.isMainFrame { return decisionHandler(.allow) }
        if allowInitialLoad, action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
            allowInitialLoad = false
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        guard let url = action.request.url else { return }
        if action.navigationType == .linkActivated { host?.openLink(url) }
        else { host?.bridge.report(.blockedNavigation(url.absoluteString)) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.bridge.report(.blockedNavigation(action.request.url?.absoluteString ?? "new window"))
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        host?.bridge.report(.refusedPermission("media capture"))
        decisionHandler(.deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.bridge.report(.webContentProcessTerminated)
        host?.bridge.close()
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the host.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
