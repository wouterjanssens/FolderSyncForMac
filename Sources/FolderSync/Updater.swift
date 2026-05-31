import Foundation
import AppKit

/// A release fetched from the GitHub Releases API.
struct ReleaseInfo: Identifiable, Equatable {
    var id: String { tag }
    let tag: String          // e.g. "v1.2.0"
    let version: String      // normalized, e.g. "1.2.0"
    let name: String         // human title, e.g. "FolderSync 1.2.0"
    let notes: String        // release body (markdown)
    let pageURL: URL         // html_url — "see what changed"
    let zipURL: URL          // browser_download_url of the .app zip asset
}

/// Drives the in-app update flow: checks GitHub for a newer release, then
/// downloads and swaps the running .app bundle in place.
@MainActor
final class UpdateChecker: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking
        case available          // a newer release is ready to install
        case downloading
        case installed          // swapped in place; user must reopen
        case failed(String)
        case upToDate           // only surfaced for a manual (non-silent) check
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var progress: Double = 0   // 0…1 during download

    /// True whenever there is something to show the user in a sheet.
    var hasSomethingToShow: Bool {
        switch phase {
        case .available, .downloading, .installed, .failed, .upToDate: return true
        case .idle, .checking: return false
        }
    }

    // GitHub repo that publishes releases.
    private let owner = "wouterjanssens"
    private let repo = "FolderSyncForMac"

    /// The currently running app's marketing version (CFBundleShortVersionString).
    let currentVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }()

    private var checkedThisLaunch = false

    /// Check for a newer release.
    /// - Parameter silent: when true (the automatic launch check), an "up to
    ///   date" result or a network error is swallowed rather than shown.
    func checkForUpdates(silent: Bool) async {
        // The automatic launch check should run only once per launch.
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
            if silent {
                phase = .idle
            } else {
                phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    /// Download the release zip and replace the running .app bundle in place.
    func downloadAndInstall() async {
        guard let release = available else { return }
        phase = .downloading
        progress = 0
        do {
            let zipURL = try await download(release.zipURL)
            try install(fromZip: zipURL)
            phase = .installed
        } catch {
            phase = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    /// Dismiss the current sheet. A "Later" dismissal leaves nothing persisted,
    /// so the next launch checks again.
    func dismiss() {
        // Keep `available` around only while showing it; reset transient phases.
        if phase != .downloading { phase = .idle }
    }

    // MARK: - GitHub

    private func fetchLatestRelease() async throws -> ReleaseInfo? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FolderSync-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil   // no releases yet
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }

        // Find the .app zip asset (the workflow names it FolderSync-<version>.zip).
        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let zipURL = URL(string: asset.browser_download_url),
              let pageURL = URL(string: payload.html_url) else {
            return nil
        }

        return ReleaseInfo(
            tag: payload.tag_name,
            version: normalize(payload.tag_name),
            name: payload.name?.isEmpty == false ? payload.name! : payload.tag_name,
            notes: payload.body ?? "",
            pageURL: pageURL,
            zipURL: zipURL
        )
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    // MARK: - Download & install

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("FolderSync-Updater", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // Move into a uniquely-named temp file we control with a .zip suffix.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderSync-update-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        progress = 1
        return dest
    }

    /// Unzip the downloaded archive and atomically swap it over the running bundle.
    private func install(fromZip zip: URL) throws {
        let fm = FileManager.default
        let installedURL = Bundle.main.bundleURL          // …/FolderSync.app
        guard installedURL.pathExtension == "app" else {
            throw UpdateError.notAppBundle
        }

        // 1. Extract into a scratch dir.
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("FolderSync-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, scratch.path])

        // 2. Locate the extracted FolderSync.app.
        guard let newApp = try locateApp(in: scratch) else {
            throw UpdateError.appNotFoundInZip
        }

        // 3. Clear the download quarantine so Gatekeeper doesn't re-warn on reopen.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // 4. Stage it next to the installed app (same volume → atomic moves).
        let parent = installedURL.deletingLastPathComponent()
        let staged = parent.appendingPathComponent("FolderSync.app.new")
        let backup = parent.appendingPathComponent("FolderSync.app.old")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: newApp, to: staged)

        // 5. Swap: move running bundle aside, move new one in, drop the backup.
        //    The running process keeps its open file handles, so this is safe.
        do {
            try fm.moveItem(at: installedURL, to: backup)
            try fm.moveItem(at: staged, to: installedURL)
            try? fm.removeItem(at: backup)
        } catch {
            // Roll back if the second move failed.
            if !fm.fileExists(atPath: installedURL.path),
               fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: installedURL)
            }
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Find the first *.app at the root (or one level down) of a directory.
    private func locateApp(in dir: URL) throws -> URL? {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // ditto without --keepParent can nest; check one level down just in case.
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

    // MARK: - Version compare

    /// Strip a leading "v" and trailing junk so "v1.2.0" → "1.2.0".
    private func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Semantic-ish compare: split on ".", compare numerically, pad with zeros.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
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
    case appNotFoundInZip
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "server returned status \(code)"
        case .notAppBundle: return "the app isn't running from a .app bundle"
        case .appNotFoundInZip: return "the downloaded archive didn't contain FolderSync.app"
        case .commandFailed(let msg): return msg
        }
    }
}
