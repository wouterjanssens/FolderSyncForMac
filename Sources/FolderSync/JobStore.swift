import Foundation
import SwiftUI

/// Owns the list of jobs and persists them to Application Support.
@MainActor
final class JobStore: ObservableObject {
    @Published var jobs: [SyncJob] = [] {
        didSet { if !suppressSave { save() } }
    }
    @Published var selection: UUID?

    private let fileURL: URL
    private var suppressSave = false

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("jobs.json")
        load()
        if selection == nil { selection = jobs.first?.id }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SyncJob].self, from: data) else { return }
        suppressSave = true
        jobs = decoded
        suppressSave = false
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func addJob() {
        let job = SyncJob(name: "New Job", localPath: "", remotePath: "")
        jobs.append(job)
        selection = job.id
    }

    func removeJob(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
    }

    var enabledJobs: [SyncJob] { jobs.filter { $0.enabled } }
}
