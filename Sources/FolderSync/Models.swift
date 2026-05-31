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

/// A single configured local→remote folder pair.
struct SyncJob: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var localPath: String
    var remotePath: String
    var enabled: Bool = true
    var deletionPolicy: DeletionPolicy = .moveToDeletedFolder
    var excludes: [String] = SyncJob.defaultExcludes

    static let defaultExcludes = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".DocumentRevisions-V100", "._.DS_Store"
    ]
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

/// The full result of analyzing a job: everything that *would* happen on sync.
struct SyncPlan {
    var jobID: UUID
    var items: [PlanItem]
    var errors: [String]

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

/// Live progress emitted while a sync runs.
struct SyncProgress {
    var currentFile: String
    var doneItems: Int
    var totalItems: Int
    var bytesCopied: Int64
    var totalBytes: Int64

    var fraction: Double {
        totalItems == 0 ? 1 : min(1, Double(doneItems) / Double(totalItems))
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
