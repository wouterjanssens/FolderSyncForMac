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

    /// Fixed clock for the whole workspace, so day-folder fixtures and the
    /// sync that purges them agree on what "today" is.
    let now = Date()

    /// Analyze then execute the whole plan at the workspace clock.
    @discardableResult
    func sync(policy: DeletionPolicy = .moveToDeletedFolder,
              retention: DeletedRetention = .forever) -> SyncResult {
        var job = job(policy: policy)
        job.deletedRetention = retention
        let plan = engine.analyze(job: job)
        return engine.execute(job: job, plan: plan, now: now,
                              progress: { _ in }, isCancelled: { false })
    }

    func exists(_ side: Side, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: root(side).appendingPathComponent(rel).path)
    }

    /// Relative path of `rel` inside the `_Deleted` day folder for `daysAgo`
    /// days before the workspace clock (0 = today's folder).
    func quarantined(_ rel: String, daysAgo: Int = 0) -> String {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: now)!
        return "\(SyncEngine.deletedFolderName)/\(SyncEngine.dayFolderName(for: date))/\(rel)"
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

    static func jobRoundTrip(_ job: SyncJob) throws -> SyncJob {
        let data = try JSONEncoder().encode(job)
        return try JSONDecoder().decode(SyncJob.self, from: data)
    }

    /// Decode a job saved by a version that predates `deletedRetention`.
    static func decodeLegacyJob() throws -> SyncJob {
        let json = """
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"old","localPath":"/a",
         "remotePath":"/b","enabled":true,"deletionPolicy":"moveToDeletedFolder",
         "excludes":[".DS_Store"]}
        """
        return try JSONDecoder().decode(SyncJob.self, from: Data(json.utf8))
    }

    /// Round-trips today's day-folder name through the parser.
    static func dayFolderNameRoundTrips() -> Bool {
        let name = SyncEngine.dayFolderName(for: Date())
        guard name.count == 10, let parsed = SyncEngine.dayFolderDate(name) else { return false }
        return SyncEngine.dayFolderName(for: parsed) == name
    }
}
