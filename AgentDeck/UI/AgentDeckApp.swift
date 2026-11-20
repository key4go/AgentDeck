import AppKit
import SwiftUI

@main
struct AgentDeckApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        Window("SWORAX", id: "agent-canvas") {
            DeckWindow(store: store)
                .frame(minWidth: 540, minHeight: 340)
                .background(WindowFrame())
        }
        .defaultSize(width: 540, height: 372)
        .windowResizability(.automatic)
    }
}

