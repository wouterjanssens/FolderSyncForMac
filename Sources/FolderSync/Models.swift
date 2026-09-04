import Foundation

/// How files that exist on the remote but no longer exist locally are handled.
enum DeletionPolicy: String, Codable, CaseIterable, Identifiable {
    /// Move the orphaned remote file into a `_Deleted` folder at the remote root,
    /// preserving its relative path. Safe: nothing is ever truly destroyed.
    case moveToDeletedFolder
    /// Never touch orphaned remote files. The remote only ever grows (pure backup).
    case keepOnRemote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moveToDeletedFolder: return "Move removed files to _Deleted folder"
        case .keepOnRemote:        return "Keep removed files on remote (additive only)"
        }
    }
}

/// How long quarantined files stay in `_Deleted` before they are permanently
/// removed. Only meaningful when the deletion policy is `.moveToDeletedFolder`.
enum DeletedRetention: String, Codable, CaseIterable, Identifiable {
    /// Never purge. `_Deleted` grows until emptied by hand (the historic behavior).
    case forever
    case days7
    case days30
    case days90

    var id: String { rawValue }

    /// Number of days a quarantined file is kept; nil for `.forever`.
    var days: Int? {
        switch self {
        case .forever: return nil
        case .days7:   return 7
        case .days30:  return 30
        case .days90:  return 90
        }
    }

    var label: String {
        switch self {
        case .forever: return "Never (keep forever)"
        case .days7:   return "After 7 days"
        case .days30:  return "After 30 days"
        case .days90:  return "After 90 days"
        }
    }
}

/// A single configured local→remote folder pair.
struct SyncJob: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var localPath: String
    var remotePath: String
    var enabled: Bool = true
    var deletionPolicy: DeletionPolicy = .moveToDeletedFolder
    /// When to permanently delete files that were moved into `_Deleted`.
    var deletedRetention: DeletedRetention = .forever
    var excludes: [String] = SyncJob.defaultExcludes

    static let defaultExcludes = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".DocumentRevisions-V100", "._.DS_Store"
    ]

    init(id: UUID = UUID(), name: String, localPath: String, remotePath: String,
         enabled: Bool = true,
         deletionPolicy: DeletionPolicy = .moveToDeletedFolder,
         deletedRetention: DeletedRetention = .forever,
         excludes: [String] = SyncJob.defaultExcludes) {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.remotePath = remotePath
        self.enabled = enabled
        self.deletionPolicy = deletionPolicy
        self.deletedRetention = deletedRetention
        self.excludes = excludes
    }

    // Hand-written decoding so jobs saved by older versions (which lack
    // `deletedRetention`) still load, defaulting to "keep forever".
    private enum CodingKeys: String, CodingKey {
        case id, name, localPath, remotePath, enabled, deletionPolicy, deletedRetention, excludes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        localPath = try c.decode(String.self, forKey: .localPath)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deletionPolicy = try c.decodeIfPresent(DeletionPolicy.self, forKey: .deletionPolicy) ?? .moveToDeletedFolder
        deletedRetention = try c.decodeIfPresent(DeletedRetention.self, forKey: .deletedRetention) ?? .forever
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? SyncJob.defaultExcludes
    }
}

/// The kind of change a plan item represents.
enum SyncAction: String, Codable {
    case create   // new file/folder on remote
    case move     // same content relocated/renamed -> move within remote (no re-copy)
    case update   // file content changed locally
    case delete   // remote file orphaned -> move to _Deleted

    var sortRank: Int {
        switch self {
        case .create: return 0
        case .move:   return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    var label: String {
        switch self {
        case .create: return "New"
        case .move:   return "Moved"
        case .update: return "Changed"
        case .delete: return "Removed"
        }
    }

    var symbol: String {
        switch self {
        case .create: return "plus.circle.fill"
        case .move:   return "arrow.left.arrow.right.circle.fill"
        case .update: return "arrow.triangle.2.circlepath.circle.fill"
        case .delete: return "trash.circle.fill"
        }
    }
}

/// One planned operation produced by the analysis pass.
/// For `.move`, `relativePath` is the destination (new) path and `fromPath`
/// is the current remote (old) path being moved.
struct PlanItem: Identifiable, Hashable {
    let id = UUID()
    let action: SyncAction
    let relativePath: String
    let size: Int64
    let isDirectory: Bool
    var fromPath: String? = nil
}

/// A folder in a size-breakdown tree. `totalBytes` and `fileCount` are
/// cumulative (this folder's own files plus every descendant), so a parent
/// always sums its children. Children are sorted largest-first.
struct FolderSizeNode: Identifiable {
    let name: String            // folder name; "" for the root
    let relativePath: String    // "" for the root
    let totalBytes: Int64       // cumulative: own files + all descendants
    let fileCount: Int          // cumulative file count (directories excluded)
    let directFileBytes: Int64  // bytes of files sitting directly in this folder
    let children: [FolderSizeNode]

    var id: String { relativePath }
}

/// The full result of analyzing a job: everything that *would* happen on sync.
struct SyncPlan {
    var jobID: UUID
    var items: [PlanItem]
    var errors: [String]
    /// Size breakdown of each side, built from the same scan that produced the
    /// plan. Nil when the corresponding folder could not be scanned.
    var localSizes: FolderSizeNode? = nil
    var remoteSizes: FolderSizeNode? = nil

    var createCount: Int { items.lazy.filter { $0.action == .create }.count }
    var moveCount: Int { items.lazy.filter { $0.action == .move }.count }
    var updateCount: Int { items.lazy.filter { $0.action == .update }.count }
    var deleteCount: Int { items.lazy.filter { $0.action == .delete }.count }

    var bytesToCopy: Int64 {
        items.lazy
            .filter { ($0.action == .create || $0.action == .update) && !$0.isDirectory }
            .reduce(0) { $0 + $1.size }
    }

    var isEmpty: Bool { items.isEmpty }
}

/// Live progress emitted while an analysis runs.
struct AnalyzeProgress {
    var phase: String = ""
    var filesSeen: Int = 0          // running count during a scan
    var checked: Int = 0            // move-detection: candidates examined
    var total: Int = 0              // move-detection: candidates to examine
    var currentFile: String = ""
    var fraction: Double? = nil     // nil => indeterminate (unknown total)
}

/// Live progress emitted while a sync runs.
struct SyncProgress {
    var phase: String = ""
    var currentFile: String = ""
    var doneItems: Int = 0
    var totalItems: Int = 0
    var bytesCopied: Int64 = 0
    var totalBytes: Int64 = 0
    var currentSpeed: Double = 0   // bytes / second, recent window
    var averageSpeed: Double = 0   // bytes / second, whole session
    var etaSeconds: Double? = nil

    /// Primary bar position. Byte-based when there is data to copy; otherwise
    /// falls back to item count (e.g. a job that is only moves/deletes).
    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(bytesCopied) / Double(totalBytes)) }
        return totalItems == 0 ? 1 : min(1, Double(doneItems) / Double(totalItems))
    }
}

/// Outcome of an executed sync.
struct SyncResult {
    var created: Int = 0
    var moved: Int = 0
    var updated: Int = 0
    var deletedMoved: Int = 0
    var dirsCreated: Int = 0
    var bytesCopied: Int64 = 0
    /// Files permanently removed from `_Deleted` because they outlived the
    /// job's retention period. This is the only place data is truly destroyed.
    var purgedFiles: Int = 0
    var purgedBytes: Int64 = 0
    var errors: [String] = []
    var cancelled: Bool = false

    var totalChanges: Int { created + moved + updated + deletedMoved }
}

/// A file or directory discovered while scanning a tree.
struct FileEntry {
    let relativePath: String
    let size: Int64
    let mtime: Date
    let isDirectory: Bool
}
