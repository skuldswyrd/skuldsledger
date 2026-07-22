import SwiftUI

@main
struct SkuldsLedgerApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .background(Theme.bg)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Inbox") { store.rescanInbox() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Generate Report") { store.generateReport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Check for Updates") { store.checkForUpdates() }
            }
        }
    }
}
