import Testing
@testable import FolderSync

// Pure value-type checks on the model layer — no filesystem involved.
// Foundation lives in Support.swift; see the note there.

private func item(_ action: SyncAction, _ path: String, size: Int64 = 0,
                  isDirectory: Bool = false) -> PlanItem {
    PlanItem(action: action, relativePath: path, size: size, isDirectory: isDirectory)
}

@Test func planCountsByAction() {
    let plan = SyncPlan(jobID: TestSupport.freshID(), items: [
        item(.create, "a.txt"),
        item(.create, "b.txt"),
        item(.update, "c.txt"),
        item(.move, "d.txt"),
        item(.delete, "e.txt"),
    ], errors: [])

    #expect(plan.createCount == 2)
    #expect(plan.updateCount == 1)
    #expect(plan.moveCount == 1)
    #expect(plan.deleteCount == 1)
    #expect(!plan.isEmpty)
}

@Test func bytesToCopyCountsOnlyCreatesAndUpdatedFiles() {
    let plan = SyncPlan(jobID: TestSupport.freshID(), items: [
        item(.create, "new.bin", size: 100),
        item(.update, "changed.bin", size: 50),
        item(.create, "dir", size: 0, isDirectory: true), // dirs excluded
        item(.move, "moved.bin", size: 999),              // moves don't re-copy
        item(.delete, "gone.bin", size: 999),             // deletes don't copy
    ], errors: [])

    #expect(plan.bytesToCopy == 150)
}

@Test func emptyPlanIsEmpty() {
    let plan = SyncPlan(jobID: TestSupport.freshID(), items: [], errors: [])
    #expect(plan.isEmpty)
    #expect(plan.bytesToCopy == 0)
}

@Test func progressFractionPrefersBytesWhenAvailable() {
    var p = SyncProgress()
    p.totalBytes = 200
    p.bytesCopied = 50
    p.totalItems = 10
    p.doneItems = 9 // should be ignored while bytes drive the bar
    #expect(abs(p.fraction - 0.25) < 0.0001)
}

@Test func progressFractionFallsBackToItemsWithoutBytes() {
    var p = SyncProgress()
    p.totalBytes = 0
    p.totalItems = 4
    p.doneItems = 1
    #expect(abs(p.fraction - 0.25) < 0.0001)
}

@Test func progressFractionClampsToOne() {
    var p = SyncProgress()
    p.totalBytes = 100
    p.bytesCopied = 250
    #expect(abs(p.fraction - 1.0) < 0.0001)
}

@Test func progressFractionIsFullWhenNothingToDo() {
    let p = SyncProgress() // no bytes, no items
    #expect(abs(p.fraction - 1.0) < 0.0001)
}

@Test func syncResultTotalChanges() {
    var r = SyncResult()
    r.created = 3
    r.moved = 1
    r.updated = 2
    r.deletedMoved = 4
    r.dirsCreated = 5 // not counted toward changes
    #expect(r.totalChanges == 10)
}

@Test func actionSortRankOrdering() {
    let order: [SyncAction] = [.delete, .update, .move, .create]
    let sorted = order.sorted { $0.sortRank < $1.sortRank }
    #expect(sorted == [.create, .move, .update, .delete])
}

@Test func deletionPolicyIsCodableRoundTrip() throws {
    for policy in DeletionPolicy.allCases {
        #expect(try TestSupport.codableRoundTrip(policy) == policy)
    }
}

@Test func syncJobHasDefaultExcludes() {
    let job = SyncJob(name: "x", localPath: "/a", remotePath: "/b")
    #expect(job.excludes.contains(".DS_Store"))
    #expect(job.enabled)
    #expect(job.deletionPolicy == .moveToDeletedFolder)
}
