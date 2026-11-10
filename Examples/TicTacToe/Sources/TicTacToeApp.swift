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
        let text = message["content"]?["text"]?.stringValue ?? message.jsonString()
        record("ui/message \(text)")
        chat.append(text)
        return true
    }

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

struct ChatScreen: View {
    @State private var host = FakeHost()
    @State private var app: MCPAppWebHost?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Let's play tic-tac-toe.")
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Sure. You're X.")
                    if let app {
                        MCPAppView(host: app, minHeight: 200, maxHeight: 520)
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
                            ForEach(host.log.suffix(6)) { Text($0.text).font(.caption2.monospaced()).lineLimit(2) }
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
              let url = Bundle.main.url(forResource: "tic-tac-toe", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              let resource = try? MCPAppResource(content: [
                  "uri": "ui://tic-tac-toe/board", "mimeType": .string(MCPAppProtocol.resourceMIMEType), "text": .string(html),
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
