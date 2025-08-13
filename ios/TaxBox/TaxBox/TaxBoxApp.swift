import SwiftUI

@main
struct TaxBoxApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Import from CSV...") {
                    model.showCSVImport()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Tax Box") {
                Button("Open Root Folder") { model.openRootInFinder() }
                Button(model.copyOnImport ? "Import Mode: Copy" : "Import Mode: Move") { model.copyOnImport.toggle() }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}