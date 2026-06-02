import Testing
@testable import FolderSync

// Exercises the scan + analyze pipeline against real temporary directories.
// All Foundation plumbing (URL/FileManager/Date) is in Support.swift.

@Test func scanSkipsExcludedNames() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.local, "keep.txt", "a")
    try ws.write(.local, ".DS_Store", "junk")
    try ws.write(.local, "sub/nested.txt", "b")

    let (files, errors) = ws.scan(.local, excludes: [".DS_Store"])
    #expect(errors.isEmpty)
    #expect(files["keep.txt"] != nil)
    #expect(files["sub/nested.txt"] != nil)
    #expect(files["sub"] != nil)
    #expect(files[".DS_Store"] == nil)
}

@Test func scanSkipsTopLevelFolder() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.remote, "real.txt", "a")
    try ws.write(.remote, "_Deleted/old.txt", "b")

    let (files, _) = ws.scan(.remote, excludes: [], skipTopLevel: SyncEngine.deletedFolderName)
    #expect(files["real.txt"] != nil)
    #expect(files["_Deleted"] == nil)
    #expect(files["_Deleted/old.txt"] == nil)
}

@Test func analyzeReportsMissingFolders() {
    let plan = TestSupport.analyzeMissingFolders()
    #expect(plan.isEmpty)
    #expect(plan.errors.count == 2)
}

@Test func analyzeDetectsNewFiles() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.local, "a.txt", "hello")
    try ws.write(.local, "dir/b.txt", "world")

    let plan = ws.analyze()
    #expect(plan.errors.isEmpty)
    // Two new files plus the new directory.
    #expect(plan.createCount == 3)
    #expect(plan.bytesToCopy == Int64("hello".count + "world".count))
}

@Test func analyzeDetectsChangedFileBySize() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.local, "a.txt", "longer content")
    try ws.write(.remote, "a.txt", "short")

    let plan = ws.analyze()
    #expect(plan.updateCount == 1)
    #expect(plan.createCount == 0)
}

@Test func analyzeSkipsIdenticalFiles() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.local, "a.txt", "same")
    try ws.write(.remote, "a.txt", "same")
    // Align mtimes so nothing looks newer than the tolerance window.
    try ws.setMTime(.local, "a.txt", 1_000_000)
    try ws.setMTime(.remote, "a.txt", 1_000_000)

    let plan = ws.analyze()
    #expect(plan.isEmpty)
}

@Test func analyzeQuarantinesOrphansUnderMovePolicy() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.remote, "gone.txt", "orphan")

    let plan = ws.analyze(policy: .moveToDeletedFolder)
    #expect(plan.deleteCount == 1)
}

@Test func analyzeKeepsOrphansUnderAdditivePolicy() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.remote, "gone.txt", "orphan")

    let plan = ws.analyze(policy: .keepOnRemote)
    #expect(plan.deleteCount == 0)
    #expect(plan.isEmpty)
}

@Test func buildSizeTreeRollsUpCumulativeSizes() {
    // a.txt (3) at root, sub/b.txt (4) and sub/deep/c.txt (5) nested.
    let map: [String: FileEntry] = [
        "a.txt":          FileEntry(relativePath: "a.txt", size: 3, mtime: .distantPast, isDirectory: false),
        "sub":            FileEntry(relativePath: "sub", size: 0, mtime: .distantPast, isDirectory: true),
        "sub/b.txt":      FileEntry(relativePath: "sub/b.txt", size: 4, mtime: .distantPast, isDirectory: false),
        "sub/deep":       FileEntry(relativePath: "sub/deep", size: 0, mtime: .distantPast, isDirectory: true),
        "sub/deep/c.txt": FileEntry(relativePath: "sub/deep/c.txt", size: 5, mtime: .distantPast, isDirectory: false),
    ]
    let root = SyncEngine.buildSizeTree(rootName: "root", from: map)

    #expect(root.totalBytes == 12)        // 3 + 4 + 5
    #expect(root.fileCount == 3)
    #expect(root.directFileBytes == 3)    // only a.txt sits directly at the root

    let sub = root.children.first { $0.name == "sub" }
    #expect(sub?.totalBytes == 9)         // 4 + 5
    #expect(sub?.fileCount == 2)
    #expect(sub?.directFileBytes == 4)    // only b.txt sits directly in sub

    let deep = sub?.children.first { $0.name == "deep" }
    #expect(deep?.totalBytes == 5)
    #expect(deep?.children.isEmpty == true)
}

@Test func buildSizeTreeSortsChildrenLargestFirst() {
    let map: [String: FileEntry] = [
        "small/x": FileEntry(relativePath: "small/x", size: 1, mtime: .distantPast, isDirectory: false),
        "big/y":   FileEntry(relativePath: "big/y", size: 100, mtime: .distantPast, isDirectory: false),
        "mid/z":   FileEntry(relativePath: "mid/z", size: 10, mtime: .distantPast, isDirectory: false),
    ]
    let root = SyncEngine.buildSizeTree(rootName: "root", from: map)
    #expect(root.children.map(\.name) == ["big", "mid", "small"])
}

@Test func analyzeProducesSizeTreesForBothSides() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    try ws.write(.local, "docs/a.txt", "hello")
    try ws.write(.remote, "old.txt", "x")

    let plan = ws.analyze()
    #expect(plan.localSizes != nil)
    #expect(plan.remoteSizes != nil)
    #expect(plan.localSizes?.totalBytes == Int64("hello".count))
    #expect(plan.localSizes?.children.first?.name == "docs")
}

@Test func analyzeDetectsMoveInsteadOfCreatePlusDelete() throws {
    let ws = try TempWorkspace(); defer { ws.cleanup() }
    // Same content at a new local path; the orphaned remote copy should be
    // recognised as a move rather than a re-copy + quarantine.
    let body = "identical bytes for move detection"
    try ws.write(.local, "new/location.txt", body)
    try ws.write(.remote, "old/location.txt", body)
    try ws.setMTime(.local, "new/location.txt", 2_000_000)
    try ws.setMTime(.remote, "old/location.txt", 2_000_000)

    let plan = ws.analyze()
    #expect(plan.moveCount == 1)
    #expect(plan.deleteCount == 0)
    let move = plan.items.first { $0.action == .move }
    #expect(move?.relativePath == "new/location.txt")
    #expect(move?.fromPath == "old/location.txt")
}
