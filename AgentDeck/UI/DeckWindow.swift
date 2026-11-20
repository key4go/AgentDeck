import AppKit
import SwiftUI

enum DeckStyle {
    static let background = Color(red: 9 / 255, green: 9 / 255, blue: 11 / 255)
    static let secondaryBackground = Color(red: 17 / 255, green: 17 / 255, blue: 20 / 255)
    static let surface = Color(red: 27 / 255, green: 27 / 255, blue: 32 / 255)
    static let primaryText = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let secondaryText = Color(red: 154 / 255, green: 154 / 255, blue: 163 / 255)
    static let mutedText = Color(red: 102 / 255, green: 102 / 255, blue: 112 / 255)
    static let accent = Color(red: 230 / 255, green: 59 / 255, blue: 75 / 255)
    static let line = Color.white.opacity(0.10)

    static var chrome: some View {
        ZStack {
            secondaryBackground
            Rectangle().fill(.ultraThinMaterial).opacity(0.25)
            LinearGradient(colors: [.white.opacity(0.035), .clear], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var radius: CGFloat = 7
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, radius: radius, active: active)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let radius: CGFloat
    let active: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .background {
                shape.fill(DeckStyle.surface)
                    .overlay {
                        shape.fill(LinearGradient(colors: [Color.white.opacity(configuration.isPressed ? 0.02 : (hovering ? 0.10 : 0.055)), .clear], startPoint: .top, endPoint: .bottom))
                    }
            }
            .overlay {
                shape.strokeBorder(focused ? DeckStyle.primaryText.opacity(0.8) : (active ? DeckStyle.accent.opacity(0.45) : .white.opacity(hovering ? 0.20 : 0.12)), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.30 : 0.18), radius: hovering ? 5 : 3, y: 2)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}


struct DeckWindow: View {
    let store: WorkspaceStore
    @AppStorage("selectedMainChat") private var selectedChat = ""
    @State private var showStatus = false

    private var chat: CodexThread? {
        store.mainChats.first { $0.id == selectedChat }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DeckStyle.line)
            if let chat {
                VStack(spacing: 0) {
                    if !store.chatAttached(chat.id) {
                        HStack {
                            if store.isAttachingChat(chat.id) {
                                ProgressView().controlSize(.small)
                                Text("Connecting chat…").font(.caption)
                            } else {
                                Text("Connect this main chat to delegate tasks.").font(.caption)
                            }
                            Spacer()
                            Button("Connect chat") { Task { _ = await store.attachChat(chat.id) } }
                                .disabled(!store.connected || store.isAttachingChat(chat.id))
                        }.padding(8)
                    }
                    CompactWhiteboard(store: store, project: Project(folder: chat.folder), chatID: chat.id)
                }.id(chat.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Choose a main chat").font(.headline)
                    Text("Select the Codex conversation your subagents will work in.").foregroundStyle(.secondary)
                    Button("Refresh chats") { Task { await store.refreshObservedSessions() } }.disabled(!store.connected)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeckStyle.background)
        .preferredColorScheme(.dark)
        .tint(DeckStyle.accent)
        .sheet(isPresented: $showStatus) { statusSheet }
        .task {
            await store.connect()
            if let chat { _ = await store.attachChat(chat.id) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                guard !Task.isCancelled else { break }
                await store.refreshObservedSessions()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.mainChats) { chat in
                    Button {
                        selectedChat = chat.id
                        Task { _ = await store.attachChat(chat.id) }
                    } label: {
                        if chat.id == self.chat?.id {
                            Label(chat.title, systemImage: "checkmark")
                        } else {
                            Text(chat.title)
                        }
                    }
                }
                Divider()
                if store.hasMoreProjects { Button("Load older chats") { Task { await store.loadMoreProjects() } } }
                Button("Refresh chats") { Task { await store.refreshObservedSessions() } }.disabled(!store.connected)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(chat?.title ?? "Choose main chat").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Choose main chat")
            .help("Choose a main chat")
            .frame(maxWidth: 240, alignment: .leading)
            Spacer(minLength: 4)
            Button { showStatus = true } label: {
                HStack(spacing: 5) {
                    Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(store.connectionStatus).lineLimit(1)
                    if store.error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                    if !store.approvals.isEmpty {
                        Text("\(store.approvals.count)")
                            .font(.caption.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Connection and approvals")
            .help("Connection and approvals")
        }
        .padding(.horizontal, 14).frame(height: 44)
        .foregroundStyle(DeckStyle.primaryText)
        .background(DeckStyle.chrome)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var statusSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection & Approvals").font(.headline)
                Spacer()
                Button("Done") { showStatus = false }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.connectionStatus).font(.subheadline.bold())
                    Text("Uses Codex’s shared local server. Open Codex before connecting.").font(.caption).foregroundStyle(.secondary)
                    Text("AgentDeck \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development") · Server: \(store.serverVersion)").font(.caption).foregroundStyle(.secondary)
                    Text(store.executable?.path ?? "Codex executable not found")
                        .font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Choose Executable…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK { store.executable = panel.url }
                        }
                        if store.connected {
                            Button("Disconnect") { Task { await store.disconnect() } }
                                .disabled(store.hasActiveWork)
                                .help("Finish or interrupt active work before disconnecting.")
                        } else {
                            Button("Connect") { Task { await store.connect() } }
                                .disabled(store.connecting || store.executable == nil)
                        }
                    }
                    if let error = store.error {
                        HStack(alignment: .top) {
                            Text(error).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { store.dismissError() }
                        }.foregroundStyle(.red)
                    }
                    Divider()
                    Text("Approvals").font(.headline)
                    if store.approvals.isEmpty {
                        Text("No pending approvals.").foregroundStyle(.secondary)
                    }
                    ForEach(store.approvals) { approval in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(approval.kind.rawValue).font(.subheadline.bold())
                            if let reason = approval.reason { Text(reason) }
                            Text(approval.details).textSelection(.enabled)
                            HStack {
                                Button("Decline") { Task { await store.decide(approval.id, allow: false) } }
                                Button("Allow") { Task { await store.decide(approval.id, allow: true) } }
                                    .disabled(!approval.canAllow)
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18).frame(width: 470, height: 340)
    }
}

struct WindowFrame: NSViewRepresentable {
    final class Probe: NSView {
        private var configured = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !configured else { return }
            configured = true
            window.appearance = NSAppearance(named: .darkAqua)
            _ = window.setFrameAutosaveName("AgentDeck Actual Compact Window")
            _ = window.setFrameUsingName("AgentDeck Actual Compact Window")
            var frame = window.frame
            frame.origin.y += frame.height - 400
            frame.size = NSSize(width: 540, height: 400)
            window.minSize = frame.size
            window.setFrame(frame, display: false)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
