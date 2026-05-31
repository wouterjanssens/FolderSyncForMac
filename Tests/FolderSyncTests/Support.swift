import Foundation
@testable import FolderSync

// All Foundation-dependent test plumbing lives here. The actual @Test functions
// import the swift-testing `Testing` module instead, and the two must not be
// imported in the same file — the Foundation cross-import overlay isn't always
// present in command-line toolchains, so keeping them apart keeps the suite
// buildable everywhere.

enum Side { case local, remote }

/// A throwaway local/remote directory pair for exercising the sync engine
/// against the real filesystem. Call `cleanup()` (via `defer`) when done.
final class TempWorkspace {
    let engine = SyncEngine()
    let tmp: URL
    let local: URL
    let remote: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FolderSyncTests-\(UUID().uuidString)", isDirectory: true)
        local = tmp.appendingPathComponent("local", isDirectory: true)
        remote = tmp.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }

    private func root(_ side: Side) -> URL { side == .local ? local : remote }

    /// Write `contents` to `rel` under the given side, creating parent dirs.
    func write(_ side: Side, _ rel: String, _ contents: String) throws {
        let url = root(side).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }

    /// Force a file's modification time (seconds since 1970) so analysis is
    /// deterministic regardless of how fast the test ran.
    func setMTime(_ side: Side, _ rel: String, _ epoch: Double) throws {
        let url = root(side).appendingPathComponent(rel)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: url.path)
    }

    func job(policy: DeletionPolicy = .moveToDeletedFolder) -> SyncJob {
        SyncJob(name: "t", localPath: local.path, remotePath: remote.path, deletionPolicy: policy)
    }

    func analyze(policy: DeletionPolicy = .moveToDeletedFolder) -> SyncPlan {
        engine.analyze(job: job(policy: policy))
    }

    func scan(_ side: Side, excludes: Set<String>,
              skipTopLevel: String? = nil) -> (files: [String: FileEntry], errors: [String]) {
        engine.scan(root: root(side), excludes: excludes, skipTopLevel: skipTopLevel)
    }
}

/// Foundation-backed helpers usable from the Testing-only files.
enum TestSupport {
    static func freshID() -> UUID { UUID() }

    static func analyzeMissingFolders() -> SyncPlan {
        SyncEngine().analyze(job: SyncJob(name: "t", localPath: "/nope/local",
                                          remotePath: "/nope/remote"))
    }

    static func codableRoundTrip(_ policy: DeletionPolicy) throws -> DeletionPolicy {
        let data = try JSONEncoder().encode(policy)
        return try JSONDecoder().decode(DeletionPolicy.self, from: data)
    }
}
