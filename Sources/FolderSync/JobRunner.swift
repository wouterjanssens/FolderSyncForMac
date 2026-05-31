import Foundation
import SwiftUI

/// Tiny thread-safe boolean used to signal cancellation across threads.
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: Bool) { lock.lock(); stored = newValue; lock.unlock() }
}

/// Drives Analyze / Sync for a single job and publishes UI state.
@MainActor
final class JobRunner: ObservableObject {
    @Published var plan: SyncPlan?
    @Published var isAnalyzing = false
    @Published var isSyncing = false
    @Published var progress: SyncProgress?
    @Published var result: SyncResult?

    private let engine = SyncEngine()
    private let cancelFlag = AtomicBool(false)

    var canSync: Bool {
        guard let plan else { return false }
        return !plan.isEmpty && plan.errors.isEmpty && !isSyncing && !isAnalyzing
    }

    func analyze(job: SyncJob) {
        guard !isAnalyzing && !isSyncing else { return }
        isAnalyzing = true
        result = nil
        plan = nil
        let engine = engine
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = engine.analyze(job: job)
            DispatchQueue.main.async {
                self.plan = plan
                self.isAnalyzing = false
            }
        }
    }

    func sync(job: SyncJob) {
        guard let plan, canSync else { return }
        isSyncing = true
        result = nil
        cancelFlag.set(false)
        let engine = engine
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let result = engine.execute(
                job: job,
                plan: plan,
                progress: { p in DispatchQueue.main.async { self.progress = p } },
                isCancelled: { flag.value }
            )
            DispatchQueue.main.async {
                self.result = result
                self.isSyncing = false
                self.progress = nil
                self.plan = nil
            }
        }
    }

    func cancel() { cancelFlag.set(true) }

    func reset() {
        plan = nil
        result = nil
        progress = nil
    }
}
