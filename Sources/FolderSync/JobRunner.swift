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
    @Published var analyzeProgress: AnalyzeProgress?
    @Published var result: SyncResult?
    /// IDs of plan items the user wants to include in the next sync.
    /// Everything is included by default after an analysis.
    @Published var includedIDs: Set<UUID> = []

    private let engine = SyncEngine()
    private let cancelFlag = AtomicBool(false)

    var canSync: Bool {
        guard let plan else { return false }
        return plan.errors.isEmpty && !includedIDs.isEmpty && !isSyncing && !isAnalyzing
    }

    // MARK: Selection

    func isIncluded(_ item: PlanItem) -> Bool { includedIDs.contains(item.id) }

    func toggle(_ item: PlanItem) {
        if includedIDs.contains(item.id) { includedIDs.remove(item.id) }
        else { includedIDs.insert(item.id) }
    }

    func setIncluded(_ items: [PlanItem], _ on: Bool) {
        if on { includedIDs.formUnion(items.map(\.id)) }
        else { includedIDs.subtract(items.map(\.id)) }
    }

    /// Items from the current plan that are currently included.
    var includedItems: [PlanItem] { plan?.items.filter { includedIDs.contains($0.id) } ?? [] }

    func analyze(job: SyncJob) {
        guard !isAnalyzing && !isSyncing else { return }
        isAnalyzing = true
        result = nil
        plan = nil
        analyzeProgress = AnalyzeProgress(phase: "Starting…")
        cancelFlag.set(false)
        let engine = engine
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = engine.analyze(job: job, isCancelled: { flag.value }, progress: { ap in
                DispatchQueue.main.async { self.analyzeProgress = ap }
            })
            DispatchQueue.main.async {
                // If cancelled, drop the partial work entirely — never show
                // results for an analysis the user stopped.
                if flag.value {
                    self.plan = nil
                    self.includedIDs = []
                } else {
                    self.plan = plan
                    self.includedIDs = Set(plan.items.map(\.id))   // everything checked by default
                }
                self.isAnalyzing = false
                self.analyzeProgress = nil
            }
        }
    }

    func sync(job: SyncJob) {
        guard let plan, canSync else { return }
        // Only sync the items the user left checked.
        let filtered = SyncPlan(jobID: plan.jobID,
                                items: plan.items.filter { includedIDs.contains($0.id) },
                                errors: plan.errors)
        guard !filtered.items.isEmpty else { return }
        isSyncing = true
        result = nil
        cancelFlag.set(false)
        let engine = engine
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let result = engine.execute(
                job: job,
                plan: filtered,
                progress: { p in DispatchQueue.main.async { self.progress = p } },
                isCancelled: { flag.value }
            )
            DispatchQueue.main.async {
                self.result = result
                self.isSyncing = false
                self.progress = nil
                self.plan = nil
                self.includedIDs = []
            }
        }
    }

    func cancel() { cancelFlag.set(true) }

    func reset() {
        plan = nil
        result = nil
        progress = nil
        includedIDs = []
    }
}

/// Holds one long-lived `JobRunner` per job, keyed by job id.
///
/// The detail view only renders the *selected* job, so its runner can't live in
/// the view: switching jobs in the sidebar would tear the runner down and discard
/// any in-flight analysis. Keeping runners here lets analyses for several jobs run
/// concurrently and survive switching the selection.
@MainActor
final class RunnerStore: ObservableObject {
    private var runners: [UUID: JobRunner] = [:]

    func runner(for id: UUID) -> JobRunner {
        if let existing = runners[id] { return existing }
        let runner = JobRunner()
        runners[id] = runner
        return runner
    }

    /// Drop the runner for a removed job so its state is released.
    func discard(_ id: UUID) { runners[id] = nil }
}
