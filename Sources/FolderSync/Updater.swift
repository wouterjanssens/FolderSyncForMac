import Foundation
import AppKit

/// A release discovered on GitHub.
struct ReleaseInfo: Identifiable, Equatable {
    var id: String { tag }
    let tag: String          // e.g. "v1.2.0"
    let version: String      // normalized, e.g. "1.2.0"
    let pageURL: URL         // the release page — "see what changed"
    let zipURL: URL          // direct download of the .app zip asset
}

/// Drives the in-app update flow.
///
/// Version checks use the **non-API** `github.com/<repo>/releases/latest`
/// redirect, which returns the latest tag without consuming the 60/hour
/// unauthenticated `api.github.com` rate limit. The update itself is applied by
/// a small detached helper script that waits for the app to quit, swaps the
/// bundle, and relaunches — so it works even though the app can't overwrite
/// itself while running.
@MainActor
final class UpdateChecker: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking
        case available          // a newer release exists
        case downloading
        case readyToRelaunch    // downloaded & staged; quit+relaunch to apply
        case failed(String)
        case upToDate           // only shown for a manual (non-silent) check
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var progress: Double = 0

    var hasSomethingToShow: Bool {
        switch phase {
        case .available, .downloading, .readyToRelaunch, .failed, .upToDate: return true
        case .idle, .checking: return false
        }
    }

    private let owner = "wouterjanssens"
    private let repo = "FolderSyncForMac"

    let currentVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }()

    private var checkedThisLaunch = false

    /// Paths prepared by `downloadAndInstall`, applied by `finishUpdate`.
    private var pendingHelperScript: URL?

    // MARK: - Check

    func checkForUpdates(silent: Bool) async {
        if silent {
            guard !checkedThisLaunch else { return }
            checkedThisLaunch = true
        }
        guard phase != .checking, phase != .downloading else { return }

        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            if let release, isNewer(release.version, than: currentVersion) {
                available = release
                phase = .available
            } else {
                available = nil
                phase = silent ? .idle : .upToDate
            }
        } catch {
            available = nil
            phase = silent ? .idle : .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Resolve the latest release via the releases/latest redirect (no API,
    /// no rate limit). The redirect target encodes the tag.
    private func fetchLatestRelease() async throws -> ReleaseInfo? {
        let url = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("FolderSync-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (_, response) = try await URLSession.shared.data(for: request, delegate: RedirectBlocker())
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badStatus(-1) }

        // A repo with no releases redirects to .../releases (no /tag/), or 404s.
        guard (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let pageURL = URL(string: location),
              location.contains("/releases/tag/") else {
            return nil
        }

        let tag = (location as NSString).lastPathComponent           // "v1.2.0"
        let version = normalize(tag)                                  // "1.2.0"
        // The release workflow names the asset FolderSync-<version>.zip.
        let zipString = "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/FolderSync-\(version).zip"
        guard let zipURL = URL(string: zipString) else { return nil }

        return ReleaseInfo(tag: tag, version: version, pageURL: pageURL, zipURL: zipURL)
    }

    /// Blocks redirect following so we can read the 3xx `Location` header.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // don't follow — surface the 3xx response
        }
    }

    // MARK: - Download & stage

    func downloadAndInstall() async {
        guard let release = available else { return }
        phase = .downloading
        progress = 0
        do {
            let zip = try await download(release.zipURL)
            let script = try stageUpdate(fromZip: zip)
            pendingHelperScript = script
            phase = .readyToRelaunch
        } catch {
            phase = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("FolderSync-Updater", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderSync-update-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        progress = 1
        return dest
    }

    /// Extract the zip and write a helper script that performs the swap after
    /// the app quits. Returns the helper script URL. Throws (before any
    /// destructive step) if the app can't be safely updated in place.
    private func stageUpdate(fromZip zip: URL) throws -> URL {
        let fm = FileManager.default
        let dest = Bundle.main.bundleURL                       // …/FolderSync.app

        guard dest.pathExtension == "app" else { throw UpdateError.notAppBundle }

        // App Translocation: a quarantined app opened straight from Downloads
        // runs from a read-only randomized path. We can't update it in place.
        guard !dest.path.contains("/AppTranslocation/") else {
            throw UpdateError.translocated
        }

        let parent = dest.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        // Extract into a scratch dir the helper will clean up.
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("FolderSync-update-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, scratch.path])

        guard let newApp = try locateApp(in: scratch) else {
            throw UpdateError.appNotFoundInZip
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        // Script lives OUTSIDE the scratch dir so it can delete the scratch dir
        // without removing itself mid-run.
        let scriptURL = fm.temporaryDirectory
            .appendingPathComponent("FolderSync-apply-\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        # Wait for FolderSync (pid \(pid)) to quit, then swap the bundle and relaunch.
        LOG="$HOME/Library/Logs/FolderSync-update.log"
        exec >>"$LOG" 2>&1
        echo "==== FolderSync update $(date) ===="

        DEST=\(shellQuote(dest.path))
        SRC=\(shellQuote(newApp.path))
        SCRATCH=\(shellQuote(scratch.path))
        ZIP=\(shellQuote(zip.path))
        echo "DEST=$DEST"
        echo "SRC=$SRC"

        echo "waiting for pid \(pid) to exit…"
        for _ in $(seq 1 600); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.2
        done
        echo "app exited (or wait timed out); swapping"

        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" 2>/dev/null && /usr/bin/ditto "$SRC" "$DEST"; then
            echo "swap OK"
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
            rm -rf "$DEST.old"
        else
            echo "swap FAILED — rolling back"
            rm -rf "$DEST"
            mv "$DEST.old" "$DEST" 2>/dev/null || true
        fi

        rm -f "$ZIP"
        echo "relaunching $DEST"
        if /usr/bin/open "$DEST"; then echo "open OK"; else echo "open FAILED ($?)"; fi
        rm -rf "$SCRATCH"
        echo "done"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Launch the detached helper and quit. The helper waits for this process to
    /// exit, swaps the bundle, and relaunches the new app.
    func finishUpdate() {
        guard let script = pendingHelperScript else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        do {
            try task.run()                       // orphaned → adopted by launchd on quit
        } catch {
            phase = .failed("Couldn't start the updater: \(error.localizedDescription)")
            return
        }
        // The helper only proceeds once we exit, so we MUST quit. Ask AppKit to
        // terminate, then hard-exit shortly after as a guaranteed fallback in
        // case something defers the graceful termination.
        NSApplication.shared.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
    }

    func dismiss() {
        if phase != .downloading { phase = .idle }
    }

    // MARK: - Helpers

    private func locateApp(in dir: URL) throws -> URL? {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let app = nested.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    private func run(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.commandFailed("\(launchPath) exited \(process.terminationStatus): \(msg)")
        }
    }

    /// Single-quote a string for safe embedding in the bash helper.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case badStatus(Int)
    case notAppBundle
    case translocated
    case notWritable(String)
    case appNotFoundInZip
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "server returned status \(code)"
        case .notAppBundle: return "the app isn't running from a .app bundle"
        case .translocated:
            return "FolderSync is running from a temporary location. Move FolderSync.app to your Applications folder, reopen it, then update."
        case .notWritable(let path):
            return "can't write to \(path). Move FolderSync.app somewhere you own (e.g. Applications) and try again."
        case .appNotFoundInZip: return "the downloaded archive didn't contain FolderSync.app"
        case .commandFailed(let msg): return msg
        }
    }
}
