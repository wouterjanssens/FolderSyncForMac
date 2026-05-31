# FolderSync

A small, free, native macOS app for **one-way folder sync** (local → remote), built as a
focused, no-frills personal tool. It follows a simple *Analyze → Sync* workflow
but drops everything you don't need.

## What it does

- Define any number of **jobs**, each a named *local folder → remote folder* pair.
- **Analyze** a job to preview exactly what would change, **grouped by folder**: each folder
  is collapsible and shows its own counts (new / moved / changed / removed) and the amount of
  data to copy, with per-file sizes inside. A grand total sits at the top. Nothing is touched yet.
- **Run Sync** to execute the previewed plan. Sync is strictly one-way (local → remote);
  the local source is never modified. A **byte-based progress bar** shows percent complete,
  **current and average speed (MB/s)**, and an **estimated time remaining** — large files are
  streamed in chunks so progress keeps moving mid-transfer, which matters most over the network.
- **Safe deletions:** when a file no longer exists locally, instead of deleting it on the
  remote it is **moved into a `_Deleted` folder** at the remote root, keeping its original
  subpath. So you always know what to clean up later, and nothing is ever truly lost.
  (Per-job, you can switch to "additive only" — never touch removed files.)
- **Move detection:** if a file was simply renamed or relocated locally, FolderSync detects
  it (same size + modification time, confirmed by a content hash) and **moves the existing
  file on the remote** instead of re-copying it and quarantining the old copy. This avoids
  re-transferring large files over the network for a rename. Detection runs only when the
  deletion policy is "move to _Deleted".
- Change detection uses **size + modification time** (the same heuristic rsync uses),
  with a 2-second tolerance for network-volume timestamp rounding. Re-syncing an unchanged
  folder copies nothing.
- The "remote" is just a path — point it at a local folder, an external disk under
  `/Volumes/...`, or a NAS share you've mounted in Finder.
- **Built-in updates:** on launch (and via **FolderSync → Check for Updates…**) the app
  asks GitHub for the latest release. If a newer version exists you get a prompt with a
  link to the release notes ("see what's changed") and an **Update Now** button that
  downloads the release, swaps the app in place, and asks you to reopen it. Choosing
  **Later** just dismisses it — the next launch checks again.

## Requirements

- macOS 14+ (built and tested on macOS 26).
- Swift toolchain (Command Line Tools is enough — **full Xcode is not required**).

## Download a prebuilt app

You don't have to build it yourself — each release ships a ready-to-run app:

1. Go to the [**Releases**](../../releases) page and download `FolderSync-<version>.zip`
   from the latest release.
2. Unzip it and move **FolderSync.app** to `/Applications`.
3. **First launch:** because the app is ad-hoc signed (not notarized), macOS Gatekeeper
   will flag it. Either right-click the app → **Open** → **Open**, or clear the download
   quarantine once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/FolderSync.app
   ```

> While the repo is private, downloading from a remote machine requires signing in to
> GitHub (the same `wouterjanssens` account). If the repo is later made public, the release
> zip is downloadable by anyone with no login.

### Cutting a release

A GitHub Actions workflow (`.github/workflows/release.yml`) builds the app on a macOS
runner and attaches the zip to a release. Trigger it either way:

```bash
# Tag-driven: push a version tag and the release builds automatically.
git tag v1.0.0 && git push origin v1.0.0
```

…or from the GitHub UI: **Actions → "Build & Release" → Run workflow**, then enter a tag
like `v1.0.0`. Both produce a downloadable release.

## Build & run locally

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
- `Updater.swift` — checks the GitHub Releases API, downloads the release zip, and swaps
  the running `.app` bundle in place. `UpdateView.swift` is the prompt.
- `App.swift`, `ContentView.swift`, `JobDetailView.swift` — the SwiftUI interface.

## Deliberately *not* included (kept simple)

Block-level delta transfer, two-way sync / conflict resolution, cloud protocols
(S3/FTP/SFTP/WebDAV), real-time folder monitoring, and the persistent file-state database.
The remote is always a mounted/local path.

## Possible future additions

- "Sync All Enabled" batch button across jobs.
- Scheduling (run jobs automatically via a `launchd` agent).
- Optional empty-directory cleanup on the remote.
- SFTP support for un-mounted servers.
