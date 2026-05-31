import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FolderSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = JobStore()

    var body: some Scene {
        WindowGroup("FolderSync") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Presents a folder chooser and returns the chosen POSIX path.
@MainActor
func chooseFolder(start: String?) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if let start, !start.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
    }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
