# FolderSync

A small, free, native macOS app for **one-way folder sync** (local → remote), built as a
simpler personal alternative to GoodSync. It follows GoodSync's core *Analyze → Sync* workflow
but drops everything you don't need.

## What it does

- Define any number of **jobs**, each a named *local folder → remote folder* pair.
- **Analyze** a job to preview exactly what would change: new files, changed files, and
  removed files, plus the total bytes to copy. Nothing is touched yet.
- **Run Sync** to execute the previewed plan. Sync is strictly one-way (local → remote);
  the local source is never modified.
- **Safe deletions:** when a file no longer exists locally, instead of deleting it on the
  remote it is **moved into a `_Deleted` folder** at the remote root, keeping its original
  subpath. So you always know what to clean up later, and nothing is ever truly lost.
  (Per-job, you can switch to "additive only" — never touch removed files.)
- Change detection uses **size + modification time** (the same heuristic rsync/GoodSync use),
  with a 2-second tolerance for network-volume timestamp rounding. Re-syncing an unchanged
  folder copies nothing.
- The "remote" is just a path — point it at a local folder, an external disk under
  `/Volumes/...`, or a NAS share you've mounted in Finder.

## Requirements

- macOS 14+ (built and tested on macOS 26).
- Swift toolchain (Command Line Tools is enough — **full Xcode is not required**).

## Build & run

```bash
./build.sh            # compiles and assembles FolderSync.app
open FolderSync.app   # launch it
```

To install it permanently:

```bash
cp -R FolderSync.app /Applications/
```

The first time you sync to an external disk or network volume, macOS may ask you to grant
file access — allow it.

## How it works (internals)

- `Sources/FolderSync/SyncEngine.swift` — the engine. Pure `FileManager`, no rsync dependency,
  so the `_Deleted` behavior is exact and predictable. `analyze()` walks both trees and builds
  a plan; `execute()` runs it (create dirs → copy files → move orphans to `_Deleted`).
- `Models.swift` — job, plan, and result types.
- `JobStore.swift` — persists jobs to `~/Library/Application Support/FolderSync/jobs.json`.
- `JobRunner.swift` — runs analyze/sync off the main thread with live progress + cancel.
- `App.swift`, `ContentView.swift`, `JobDetailView.swift` — the SwiftUI interface.

## Deliberately *not* included (kept simple vs. GoodSync)

Block-level delta transfer, two-way sync / conflict resolution, cloud protocols
(S3/FTP/SFTP/WebDAV), real-time folder monitoring, and the persistent file-state database.
The remote is always a mounted/local path.

## Possible future additions

- "Sync All Enabled" batch button across jobs.
- Scheduling (run jobs automatically via a `launchd` agent).
- Optional empty-directory cleanup on the remote.
- SFTP support for un-mounted servers.
