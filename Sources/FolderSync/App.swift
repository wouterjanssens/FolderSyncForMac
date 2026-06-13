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
    @StateObject private var updater = UpdateChecker()
    @StateObject private var runners = RunnerStore()

    var body: some Scene {
        WindowGroup("FolderSync") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(runners)
                .frame(minWidth: 820, minHeight: 520)
                // Check for updates once each launch. A cancelled prompt isn't
                // remembered, so the next launch checks again.
                .task { await updater.checkForUpdates(silent: true) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.checkForUpdates(silent: false) }
                }
            }
        }
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

    /// Bytes-per-second as a human MB/s-style rate.
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Seconds as a compact duration, e.g. "1h 04m", "3m 12s", "8s".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return "\(s / 3600)h \(String(format: "%02dm", (s % 3600) / 60))"
        } else if s >= 60 {
            return "\(s / 60)m \(String(format: "%02ds", s % 60))"
        }
        return "\(s)s"
    }
}
