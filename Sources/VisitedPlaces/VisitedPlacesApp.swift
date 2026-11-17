import SwiftUI
import AppKit

@main
struct VisitedPlacesApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Lets `swift run` show a proper Dock icon and menu bar too.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Visited Places") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandMenu("Mail") {
                Button("Sync & Scan Fastmail") { model.syncAndScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                Button("Re-extract Places from Cached Emails") { model.rescanAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
                Divider()
                Button("Stop") { model.cancelWork() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
