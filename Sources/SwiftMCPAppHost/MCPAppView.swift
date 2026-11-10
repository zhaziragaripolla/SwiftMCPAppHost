public import SwiftUI
import WebKit

/// Shows an MCP App in SwiftUI, sized to the height the app reports.
///
/// ```swift
/// MCPAppView(host: host, maxHeight: 500)
/// ```
public struct MCPAppView: View {
    private let host: MCPAppWebHost
    private let minHeight: CGFloat
    private let maxHeight: CGFloat

    /// - Parameters:
    ///   - host: The app to show.
    ///   - minHeight: The height before the app reports its size.
    ///   - maxHeight: Taller content is clipped, as inline apps are in Claude.
    public init(host: MCPAppWebHost, minHeight: CGFloat = 120, maxHeight: CGFloat = 600) {
        self.host = host
        self.minHeight = minHeight
        self.maxHeight = max(maxHeight, minHeight)
    }

    public var body: some View {
        WebViewContainer(host: host)
            .frame(height: min(max(CGFloat(host.contentHeight ?? Double(minHeight)), minHeight), maxHeight))
            .clipped()
            .overlay {
                if host.resource.prefersBorder ?? true {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear { host.load() }
    }
}

#if canImport(UIKit)
private struct WebViewContainer: UIViewRepresentable {
    let host: MCPAppWebHost
    func makeUIView(context: Context) -> WKWebView { host.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Shows an MCP App in UIKit. Its intrinsic height follows the height the app reports.
public final class MCPAppHostView: UIView {
    public let host: MCPAppWebHost
    public var minHeight: CGFloat = 120 { didSet { invalidateIntrinsicContentSize() } }
    public var maxHeight: CGFloat = 600 { didSet { invalidateIntrinsicContentSize() } }

    public init(host: MCPAppWebHost) {
        self.host = host
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerRadius = 12
        if host.resource.prefersBorder ?? true {
            layer.borderWidth = 0.5
            layer.borderColor = UIColor.separator.cgColor
        }
        host.webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.webView)
        NSLayoutConstraint.activate([
            host.webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.webView.topAnchor.constraint(equalTo: topAnchor),
            host.webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observeHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { host.load() }
    }

    public override var intrinsicContentSize: CGSize {
        let height = CGFloat(host.contentHeight ?? Double(minHeight))
        return CGSize(width: UIView.noIntrinsicMetric, height: min(max(height, minHeight), max(maxHeight, minHeight)))
    }

    private func observeHeight() {
        withObservationTracking { _ = host.contentHeight } onChange: { [weak self] in
            Task { @MainActor in
                self?.invalidateIntrinsicContentSize()
                self?.observeHeight()
            }
        }
    }
}
#elseif canImport(AppKit)
private struct WebViewContainer: NSViewRepresentable {
    let host: MCPAppWebHost
    func makeNSView(context: Context) -> WKWebView { host.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
