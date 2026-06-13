import Foundation
import CryptoKit

/// Pure value-type engine: scans trees, builds a one-way (local→remote) plan,
/// and executes it. No external dependencies (no rsync).
struct SyncEngine {

    static let deletedFolderName = "_Deleted"

    /// Modification-time slack to absorb filesystem timestamp granularity
    /// differences (SMB / FAT volumes often round to ~1–2 s).
    let mtimeTolerance: TimeInterval = 2

    // MARK: - Scanning

    /// Walk `root` recursively, returning a map of relativePath -> FileEntry.
    /// Names in `excludes` are skipped anywhere they appear.
    /// `skipTopLevel`, if set, prunes that single top-level folder name
    /// (used to ignore the remote `_Deleted` folder).
    func scan(root: URL,
              excludes: Set<String>,
              skipTopLevel: String? = nil,
              isCancelled: (() -> Bool)? = nil,
              onProgress: ((Int, String) -> Void)? = nil) -> (files: [String: FileEntry], errors: [String]) {
        var map: [String: FileEntry] = [:]
        var errors: [String] = []
        var lastScanEmit = Date.distantPast
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, err in
                errors.append("\(url.path): \(err.localizedDescription)")
                return true
            }
        ) else {
            errors.append("Cannot read folder: \(root.path)")
            return ([:], errors)
        }

        let rootPath = root.standardizedFileURL.path

        for case let url as URL in enumerator {
            // Stop walking promptly when the analysis is cancelled. The partial
            // map is discarded upstream — we never surface partial results.
            if isCancelled?() == true { break }
            // Drain per-iteration temporaries (URL/NSString bridging, resource
            // values). Without this, scanning a large tree on a background
            // thread accumulates autoreleased objects until the run loop drains
            // — which never happens here because we never return to one.
            autoreleasepool {
                let values = try? url.resourceValues(forKeys: keys)
                let isDir = values?.isDirectory ?? false

                // Compute path relative to root.
                var rel = url.standardizedFileURL.path
                if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
                while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                if rel.isEmpty { return }

                let lastComponent = url.lastPathComponent
                if excludes.contains(lastComponent) {
                    if isDir { enumerator.skipDescendants() }
                    return
                }

                if let skip = skipTopLevel,
                   rel == skip || rel.hasPrefix(skip + "/") {
                    if isDir { enumerator.skipDescendants() }
                    return
                }

                let size = Int64(values?.fileSize ?? 0)
                let mtime = values?.contentModificationDate ?? .distantPast
                map[rel] = FileEntry(relativePath: rel, size: size, mtime: mtime, isDirectory: isDir)

                if let onProgress {
                    let now = Date()
                    if now.timeIntervalSince(lastScanEmit) >= 0.1 {
                        lastScanEmit = now
                        onProgress(map.count, rel)
                    }
                }
            }
        }

        onProgress?(map.count, "")
        return (map, errors)
    }

    // MARK: - Analysis

    func analyze(job: SyncJob,
                 isCancelled: @escaping () -> Bool = { false },
                 progress: ((AnalyzeProgress) -> Void)? = nil) -> SyncPlan {
        let fm = FileManager.default
        // Returned when cancelled; the caller discards it so partial work is
        // never shown. Kept non-optional to leave the happy path unchanged.
        let cancelledPlan = SyncPlan(jobID: job.id, items: [], errors: [])
        let localRoot = URL(fileURLWithPath: job.localPath, isDirectory: true)
        let remoteRoot = URL(fileURLWithPath: job.remotePath, isDirectory: true)

        var errors: [String] = []
        var isDir: ObjCBool = false
        if job.localPath.isEmpty || !fm.fileExists(atPath: localRoot.path, isDirectory: &isDir) || !isDir.boolValue {
            errors.append("Local folder not found: \(job.localPath.isEmpty ? "(none set)" : job.localPath)")
        }
        if job.remotePath.isEmpty || !fm.fileExists(atPath: remoteRoot.path, isDirectory: &isDir) || !isDir.boolValue {
            errors.append("Remote folder not found: \(job.remotePath.isEmpty ? "(none set)" : job.remotePath)")
        }
        guard errors.isEmpty else {
            return SyncPlan(jobID: job.id, items: [], errors: errors)
        }

        let excludes = Set(job.excludes)
        progress?(AnalyzeProgress(phase: "Scanning local folder…"))
        let (localMap, localErrors) = scan(root: localRoot, excludes: excludes,
                                           isCancelled: isCancelled) { count, file in
            progress?(AnalyzeProgress(phase: "Scanning local folder…", filesSeen: count, currentFile: file))
        }
        if isCancelled() { return cancelledPlan }
        progress?(AnalyzeProgress(phase: "Scanning remote folder…"))
        let (remoteMap, remoteErrors) = scan(root: remoteRoot, excludes: excludes,
                                             skipTopLevel: SyncEngine.deletedFolderName,
                                             isCancelled: isCancelled) { count, file in
            progress?(AnalyzeProgress(phase: "Scanning remote folder…", filesSeen: count, currentFile: file))
        }
        if isCancelled() { return cancelledPlan }
        errors.append(contentsOf: localErrors)
        errors.append(contentsOf: remoteErrors)

        var items: [PlanItem] = []
        // Files present locally but absent on the remote — candidate creates,
        // some of which may turn out to be moves of orphaned remote files.
        var createCandidates: [FileEntry] = []

        // Creates and updates (driven by what exists locally).
        for (rel, local) in localMap {
            if local.isDirectory {
                if remoteMap[rel] == nil {
                    items.append(PlanItem(action: .create, relativePath: rel, size: 0, isDirectory: true))
                }
                continue
            }
            if let remote = remoteMap[rel], !remote.isDirectory {
                let sizeDiffers = local.size != remote.size
                let localNewer = local.mtime > remote.mtime.addingTimeInterval(mtimeTolerance)
                if sizeDiffers || localNewer {
                    items.append(PlanItem(action: .update, relativePath: rel, size: local.size, isDirectory: false))
                }
            } else {
                // Not on remote, or remote has a directory where local has a file.
                createCandidates.append(local)
            }
        }

        // Orphaned remote files (present on remote, no local counterpart).
        // Files only — orphaned directories are left in place (harmless/safe).
        var deleteCandidates: [FileEntry] = []
        if job.deletionPolicy == .moveToDeletedFolder {
            for (rel, remote) in remoteMap where !remote.isDirectory {
                if localMap[rel] == nil {
                    _ = rel
                    deleteCandidates.append(remote)
                }
            }
        }

        // Move detection: pair a create candidate with an orphaned remote file
        // that has identical content, so we move it on the remote instead of
        // re-copying and then quarantining. Only meaningful when we would
        // otherwise quarantine deletions.
        var consumedDeletes = Set<String>()
        if !deleteCandidates.isEmpty {
            // Group orphaned remote files by size for cheap candidate lookup.
            var deletesBySize: [Int64: [FileEntry]] = [:]
            for entry in deleteCandidates {
                deletesBySize[entry.size, default: []].append(entry)
            }
            let moveTotal = createCandidates.count
            var moveChecked = 0
            var lastMoveEmit = Date.distantPast
            for localEntry in createCandidates {
                if isCancelled() { return cancelledPlan }
                moveChecked += 1
                if let progress {
                    let now = Date()
                    if now.timeIntervalSince(lastMoveEmit) >= 0.1 || moveChecked == moveTotal {
                        lastMoveEmit = now
                        progress(AnalyzeProgress(phase: "Checking for moved files…",
                                                 checked: moveChecked, total: moveTotal,
                                                 currentFile: localEntry.relativePath,
                                                 fraction: moveTotal > 0 ? Double(moveChecked) / Double(moveTotal) : nil))
                    }
                }
                guard var bucket = deletesBySize[localEntry.size], !bucket.isEmpty else {
                    items.append(PlanItem(action: .create, relativePath: localEntry.relativePath,
                                          size: localEntry.size, isDirectory: false))
                    continue
                }
                // Prefer a same-size orphan with a matching mtime (a real move
                // preserves it); confirm by content before committing.
                let localFileURL = localRoot.appendingPathComponent(localEntry.relativePath)
                if let matchIndex = bucket.firstIndex(where: { remote in
                    !consumedDeletes.contains(remote.relativePath)
                        && abs(remote.mtime.timeIntervalSince(localEntry.mtime)) <= mtimeTolerance
                        && sameContent(localFileURL,
                                       remoteRoot.appendingPathComponent(remote.relativePath))
                }) {
                    let matched = bucket[matchIndex]
                    consumedDeletes.insert(matched.relativePath)
                    bucket.remove(at: matchIndex)
                    deletesBySize[localEntry.size] = bucket
                    items.append(PlanItem(action: .move, relativePath: localEntry.relativePath,
                                          size: localEntry.size, isDirectory: false,
                                          fromPath: matched.relativePath))
                } else {
                    items.append(PlanItem(action: .create, relativePath: localEntry.relativePath,
                                          size: localEntry.size, isDirectory: false))
                }
            }
        } else {
            for local in createCandidates {
                items.append(PlanItem(action: .create, relativePath: local.relativePath,
                                      size: local.size, isDirectory: false))
            }
        }

        // Remaining orphans (not matched as moves) are quarantined.
        for remote in deleteCandidates where !consumedDeletes.contains(remote.relativePath) {
            items.append(PlanItem(action: .delete, relativePath: remote.relativePath,
                                  size: remote.size, isDirectory: false))
        }

        items.sort {
            ($0.action.sortRank, $0.relativePath.lowercased())
                < ($1.action.sortRank, $1.relativePath.lowercased())
        }

        let localTree = SyncEngine.buildSizeTree(rootName: localRoot.lastPathComponent, from: localMap)
        let remoteTree = SyncEngine.buildSizeTree(rootName: remoteRoot.lastPathComponent, from: remoteMap)

        return SyncPlan(jobID: job.id, items: items, errors: errors,
                        localSizes: localTree, remoteSizes: remoteTree)
    }

    // MARK: - Size breakdown

    /// Aggregate a flat scan map into a folder tree with cumulative sizes,
    /// so the UI can show where the data actually lives. Reuses the map a
    /// scan already produced — no extra filesystem walk.
    static func buildSizeTree(rootName: String, from map: [String: FileEntry]) -> FolderSizeNode {
        // Mutable reference nodes while accumulating; frozen to value types after.
        final class Build {
            let name: String
            let path: String
            var total: Int64 = 0
            var directBytes: Int64 = 0
            var fileCount: Int = 0
            var children: [String: Build] = [:]
            init(_ name: String, _ path: String) { self.name = name; self.path = path }
        }

        let root = Build(rootName, "")
        for entry in map.values where !entry.isDirectory {
            let comps = entry.relativePath.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }
            root.total += entry.size
            root.fileCount += 1
            var node = root
            var pathSoFar = ""
            // Walk the directory components (everything but the filename),
            // rolling the size up into each ancestor along the way.
            for comp in comps.dropLast() {
                pathSoFar = pathSoFar.isEmpty ? comp : pathSoFar + "/" + comp
                let child = node.children[comp] ?? {
                    let made = Build(comp, pathSoFar)
                    node.children[comp] = made
                    return made
                }()
                child.total += entry.size
                child.fileCount += 1
                node = child
            }
            node.directBytes += entry.size   // `node` is now the immediate parent
        }

        func freeze(_ n: Build) -> FolderSizeNode {
            let kids = n.children.values.map(freeze).sorted {
                $0.totalBytes != $1.totalBytes
                    ? $0.totalBytes > $1.totalBytes
                    : $0.name.lowercased() < $1.name.lowercased()
            }
            return FolderSizeNode(name: n.name, relativePath: n.path,
                                  totalBytes: n.total, fileCount: n.fileCount,
                                  directFileBytes: n.directBytes, children: kids)
        }
        return freeze(root)
    }

    // MARK: - Execution

    func execute(job: SyncJob,
                 plan: SyncPlan,
                 progress: @escaping (SyncProgress) -> Void,
                 isCancelled: @escaping () -> Bool) -> SyncResult {
        let fm = FileManager.default
        let local = URL(fileURLWithPath: job.localPath, isDirectory: true)
        let remote = URL(fileURLWithPath: job.remotePath, isDirectory: true)

        var result = SyncResult()
        let totalItems = plan.items.count
        let totalBytes = plan.bytesToCopy
        var done = 0

        let meter = ThroughputMeter()
        var lastEmit = Date.distantPast

        func report(phase: String, file: String, force: Bool) {
            let now = Date()
            meter.record(bytes: result.bytesCopied, at: now)
            guard force || now.timeIntervalSince(lastEmit) >= 0.12 else { return }
            lastEmit = now
            let avg = meter.averageSpeed(at: now)
            let cur = meter.currentSpeed
            let speedForETA = cur > 0 ? cur : avg
            let remaining = max(0, totalBytes - result.bytesCopied)
            let eta: Double? = speedForETA > 0 ? Double(remaining) / speedForETA : nil
            progress(SyncProgress(phase: phase,
                                  currentFile: file,
                                  doneItems: done,
                                  totalItems: totalItems,
                                  bytesCopied: result.bytesCopied,
                                  totalBytes: totalBytes,
                                  currentSpeed: cur,
                                  averageSpeed: avg,
                                  etaSeconds: eta))
        }

        // 1. Create directories first, shallowest first.
        let dirs = plan.items
            .filter { $0.action == .create && $0.isDirectory }
            .sorted { $0.relativePath.count < $1.relativePath.count }
        for item in dirs {
            if isCancelled() { result.cancelled = true; return result }
            autoreleasepool {
                let dst = remote.appendingPathComponent(item.relativePath)
                do {
                    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    result.dirsCreated += 1
                } catch {
                    result.errors.append("Create folder \(item.relativePath): \(error.localizedDescription)")
                }
                done += 1
                report(phase: "Creating folders", file: item.relativePath, force: false)
            }
        }

        // 2. Relocate moved files within the remote (no re-copy). If the move
        //    fails for any reason, fall back to copying from the local source.
        for item in plan.items where item.action == .move {
            if isCancelled() { result.cancelled = true; return result }
            guard let from = item.fromPath else { continue }
            var cancelledMid = false
            autoreleasepool {
                let src = remote.appendingPathComponent(from)
                let dst = remote.appendingPathComponent(item.relativePath)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.moveItem(at: src, to: dst)
                    result.moved += 1
                } catch {
                    // Fall back to a fresh copy from the local source.
                    let localSrc = local.appendingPathComponent(item.relativePath)
                    do {
                        try copyFile(from: localSrc, to: dst, size: item.size, fm: fm,
                                     onProgress: { delta in
                                         result.bytesCopied += delta
                                         report(phase: "Copying", file: item.relativePath, force: false)
                                     }, isCancelled: isCancelled)
                        result.created += 1
                    } catch is CancellationError {
                        try? fm.removeItem(at: dst)
                        cancelledMid = true
                    } catch {
                        result.errors.append("Move \(from) → \(item.relativePath): \(error.localizedDescription)")
                    }
                }
                if !cancelledMid {
                    done += 1
                    report(phase: "Moving files", file: item.relativePath, force: true)
                }
            }
            if cancelledMid { result.cancelled = true; return result }
        }

        // 3. Copy new and changed files (streamed, with live byte progress).
        for item in plan.items where !item.isDirectory && (item.action == .create || item.action == .update) {
            if isCancelled() { result.cancelled = true; return result }
            var cancelledMid = false
            autoreleasepool {
                let src = local.appendingPathComponent(item.relativePath)
                let dst = remote.appendingPathComponent(item.relativePath)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try copyFile(from: src, to: dst, size: item.size, fm: fm,
                                 onProgress: { delta in
                                     result.bytesCopied += delta
                                     report(phase: "Copying", file: item.relativePath, force: false)
                                 }, isCancelled: isCancelled)
                    if item.action == .create { result.created += 1 } else { result.updated += 1 }
                } catch is CancellationError {
                    try? fm.removeItem(at: dst)
                    cancelledMid = true
                } catch {
                    result.errors.append("Copy \(item.relativePath): \(error.localizedDescription)")
                }
                if !cancelledMid {
                    done += 1
                    report(phase: "Copying", file: item.relativePath, force: true)
                }
            }
            if cancelledMid { result.cancelled = true; return result }
        }

        // 4. Move orphaned remote files into _Deleted, preserving subpath.
        let deletedRoot = remote.appendingPathComponent(SyncEngine.deletedFolderName, isDirectory: true)
        for item in plan.items where item.action == .delete && !item.isDirectory {
            if isCancelled() { result.cancelled = true; return result }
            autoreleasepool {
                let src = remote.appendingPathComponent(item.relativePath)
                let dst = uniqueDestination(deletedRoot.appendingPathComponent(item.relativePath), fm: fm)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    result.deletedMoved += 1
                } catch {
                    result.errors.append("Move to _Deleted \(item.relativePath): \(error.localizedDescription)")
                }
                done += 1
                report(phase: "Cleaning up removed files", file: item.relativePath, force: true)
            }
        }

        report(phase: "Done", file: "", force: true)
        return result
    }

    /// Files at or above this size are streamed in chunks so progress and
    /// speed update mid-transfer (important over the network). Smaller files
    /// use FileManager's one-shot copy, which preserves all metadata.
    private static let streamThreshold: Int64 = 8 * 1024 * 1024   // 8 MB
    private static let chunkSize = 4 * 1024 * 1024                 // 4 MB

    /// Copy a single file. `onProgress` is called with the number of bytes
    /// written since the previous call. Throws `CancellationError` if
    /// `isCancelled()` becomes true mid-transfer.
    private func copyFile(from src: URL, to dst: URL, size: Int64, fm: FileManager,
                          onProgress: (Int64) -> Void, isCancelled: () -> Bool) throws {
        guard size >= SyncEngine.streamThreshold else {
            try fm.copyItem(at: src, to: dst)
            onProgress(size)
            return
        }

        guard let input = try? FileHandle(forReadingFrom: src) else {
            // Fall back to a plain copy if we cannot open a stream.
            try fm.copyItem(at: src, to: dst)
            onProgress(size)
            return
        }
        defer { try? input.close() }

        guard fm.createFile(atPath: dst.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dst) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? output.close() }

        while true {
            if isCancelled() { throw CancellationError() }
            let chunk: Data? = autoreleasepool {
                (try? input.read(upToCount: SyncEngine.chunkSize)) ?? nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            onProgress(Int64(chunk.count))
        }

        // Preserve modification date and permissions so re-sync change detection
        // and move detection keep working as if FileManager had copied it.
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            var restore: [FileAttributeKey: Any] = [:]
            if let mdate = attrs[.modificationDate] { restore[.modificationDate] = mdate }
            if let perms = attrs[.posixPermissions] { restore[.posixPermissions] = perms }
            if !restore.isEmpty { try? fm.setAttributes(restore, ofItemAtPath: dst.path) }
        }
    }

    /// True if both files have byte-identical content. Used to confirm a
    /// suspected move (same size + mtime) before relocating instead of copying.
    /// Streams both files so large files don't load fully into memory.
    func sameContent(_ a: URL, _ b: URL) -> Bool {
        guard let ha = streamingDigest(a), let hb = streamingDigest(b) else { return false }
        return ha == hb
    }

    private func streamingDigest(_ url: URL) -> SHA256.Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MB
        var reachedEnd = false
        while !reachedEnd {
            // Drain each chunk's autoreleased Data immediately; otherwise a large
            // file's worth of 1 MB buffers piles up before the digest returns.
            autoreleasepool {
                let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
                guard let chunk, !chunk.isEmpty else { reachedEnd = true; return }
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize()
    }

    /// If `url` already exists, insert a timestamp before the extension so a
    /// prior deletion of the same path is never overwritten.
    private func uniqueDestination(_ url: URL, fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())

        var candidate = "\(base) (\(stamp))"
        var n = 1
        var result = dir.appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)")
        while fm.fileExists(atPath: result.path) {
            n += 1
            candidate = "\(base) (\(stamp)-\(n))"
            result = dir.appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)")
        }
        return result
    }
}

/// Tracks copy throughput: a whole-session average plus a recent-window
/// "current" speed. Fed cumulative byte counts as the sync progresses.
final class ThroughputMeter {
    private let start = Date()
    private var window: [(t: Date, bytes: Int64)] = []
    private let windowDuration: TimeInterval = 3

    func record(bytes: Int64, at now: Date) {
        window.append((now, bytes))
        let cutoff = now.addingTimeInterval(-windowDuration)
        while window.count > 2, let first = window.first, first.t < cutoff {
            window.removeFirst()
        }
    }

    func averageSpeed(at now: Date) -> Double {
        guard let last = window.last else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return elapsed > 0 ? Double(last.bytes) / elapsed : 0
    }

    /// Bytes/second over the most recent window.
    var currentSpeed: Double {
        guard let first = window.first, let last = window.last else { return 0 }
        let dt = last.t.timeIntervalSince(first.t)
        let db = last.bytes - first.bytes
        return dt > 0 ? Double(db) / dt : 0
    }
}
