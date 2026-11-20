import AppKit
import SwiftUI
@main struct UIRenderCheck {
    @MainActor static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let suite = "AgentDeck.UIRenderCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("observed", forKey: "selectedMainChat")
        let store = WorkspaceStore(defaults: defaults, makeClient: { AppServer() })
        store.executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/AgentDeckTests/fake-codex.py")
        await store.connect()
        var agent = AgentProfile(project: "/tmp", name: "Research", instructions: "Review the selected task.", model: "other-model", effort: "low")
        agent.parentThread = "observed"
        agent.task = "Review the authentication flow."
        precondition(store.save(agent))
        let root = DeckWindow(store: store).defaultAppStorage(defaults).background(WindowFrame())
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.title = "AgentDeck UI verification"
        host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/compact-preview.png"))
            precondition(window.frame.size == NSSize(width: 540, height: 400))
            print("Verified actual window frame is 540 × 400 including the native title bar")
        }
        let editor = NSHostingView(rootView: CompactAgentEditor(store: store, profile: agent).preferredColorScheme(.light).background(Color(nsColor: .windowBackgroundColor)))
        let details = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
        details.isReleasedWhenClosed = false
        details.contentView = editor
        try await Task.sleep(for: .milliseconds(300))
        editor.layoutSubtreeIfNeeded()
        if let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/agent-editor-preview.png"))
            print("Rendered compact agent editor with pinned primary actions")
        }
        details.close()
        await store.disconnect()
        window.close()
    }
}
