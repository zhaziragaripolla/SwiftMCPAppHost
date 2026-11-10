import SwiftUI
import SwiftMCPAppHost

@main
struct TicTacToeApp: App {
    var body: some Scene {
        WindowGroup { ChatScreen() }
    }
}

/// Plays the part of your app: its MCP client and its chat. Here the "server" is local Swift code,
/// so the example runs with no network and no API key.
@MainActor
@Observable
final class FakeHost: MCPAppHostDelegate {
    struct Entry: Identifiable {
        let id = UUID()
        let text: String
    }
    private(set) var log: [Entry] = []
    private(set) var chat: [String] = []

    func callTool(name: String, arguments: MCPJSON?) async throws -> MCPJSON {
        record("tools/call \(name) \(arguments?.jsonString() ?? "")")
        switch name {
        case "computer_move":
            let board = Array(arguments?["board"]?.stringValue ?? "")
            guard board.count == 9 else { throw MCPAppError.invalidParams("board must have 9 cells") }
            try await Task.sleep(for: .milliseconds(250))
            return ["content": [["type": "text", "text": "Moved"]], "structuredContent": ["index": .number(Double(Self.move(on: board)))]]
        case "report_result":
            return ["content": [["type": "text", "text": "Result recorded"]]]
        default:
            throw MCPAppError.methodNotFound
        }
    }

    func receiveMessage(_ message: MCPJSON) async -> Bool {
        // The spec's examples use one content object; the official SDK sends an array of them.
        let blocks = message["content"]?.arrayValue ?? [message["content"] ?? .null]
        let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
        record("ui/message \(text)")
        chat.append(text)
        return true
    }

    func openLink(_ url: URL) async -> Bool {
        record("ui/open-link \(url.absoluteString)")
        return true   // a real app would open it in the browser here
    }

    func updateModelContext(_ context: MCPJSON) async { record("ui/update-model-context \(context.jsonString())") }

    func requestDisplayMode(_ mode: MCPAppDisplayMode, current: MCPAppDisplayMode) async -> MCPAppDisplayMode {
        record("ui/request-display-mode \(mode.rawValue), staying \(current.rawValue)")
        return current
    }

    func didReceiveLog(_ params: MCPJSON?) { record("notifications/message \(params?.jsonString() ?? "")") }

    func didReport(_ diagnostic: MCPAppDiagnostic) { record("diagnostic: \(diagnostic)") }

    private func record(_ text: String) { log.append(Entry(text: text)) }

    /// Win if possible, else block, else take the centre, else the first free cell.
    static func move(on board: [Character]) -> Int {
        let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]
        let free = board.indices.filter { board[$0] == "-" }
        for mark: Character in ["O", "X"] {
            for line in lines {
                let marks = line.map { board[$0] }
                if marks.filter({ $0 == mark }).count == 2, let gap = line.first(where: { board[$0] == "-" }) { return gap }
            }
        }
        return free.contains(4) ? 4 : (free.first ?? 0)
    }
}

/// The bundled MCP Apps the example can show.
enum DemoApp: String, CaseIterable, Identifiable {
    case ticTacToe = "tic-tac-toe"
    /// Built with the official @modelcontextprotocol/ext-apps SDK by Scripts/make-sdk-probe.py.
    case sdkProbe = "sdk-probe"
    var id: String { rawValue }
    var title: String { self == .ticTacToe ? "Tic-tac-toe" : "Official SDK" }
    var isBundled: Bool { Bundle.main.url(forResource: rawValue, withExtension: "html") != nil }
}

struct ChatScreen: View {
    @State private var host = FakeHost()
    @State private var app: MCPAppWebHost?
    @State private var choice: DemoApp = .ticTacToe
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if DemoApp.sdkProbe.isBundled {
                        Picker("App", selection: $choice) {
                            ForEach(DemoApp.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Text("Let's play tic-tac-toe.")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Sure. You're X.")
                    if let app {
                        MCPAppView(host: app, minHeight: 200, maxHeight: 520)
                            .id(ObjectIdentifier(app))
                    }
                    ForEach(host.chat, id: \.self) { message in
                        Text(message)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if !host.log.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bridge log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(host.log.suffix(8)) { Text($0.text).font(.caption2.monospaced()).lineLimit(3) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("MCP App host")
            .navigationBarTitleDisplayMode(.inline)
            .task { start() }
            .onChange(of: choice) {
                let old = app
                app = nil
                Task {
                    await old?.teardown()
                    start()
                }
            }
            .onChange(of: scheme) { _, new in
                guard let app else { return }
                var context = app.bridge.hostContext
                context.theme = new == .dark ? .dark : .light
                app.bridge.setHostContext(context)
            }
        }
    }

    /// In a real app, the HTML comes from your MCP client's `resources/read` for the tool's
    /// `_meta.ui.resourceUri`. Here it's bundled, but parsed through the same path.
    private func start() {
        guard app == nil,
              let url = Bundle.main.url(forResource: choice.rawValue, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              let resource = try? MCPAppResource(content: [
                  "uri": .string("ui://example/\(choice.rawValue)"), "mimeType": .string(MCPAppProtocol.resourceMIMEType), "text": .string(html),
              ])
        else { return }
        let app = MCPAppWebHost(
            resource: resource, hostInfo: MCPAppHostInfo(name: "TicTacToe example", version: "1.0"),
            hostContext: .current(theme: scheme == .dark ? .dark : .light), delegate: host)
        self.app = app
        // The model's tool call: input, then result. Held until the app finishes its handshake.
        app.bridge.sendToolInput(["mode": "new_game"])
        app.bridge.sendToolResult(["content": [["type": "text", "text": "New game started"]]])
    }
}
