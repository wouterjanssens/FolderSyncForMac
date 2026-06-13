# FolderSync — project notes for Claude

## Releasing / deploying

When the user asks to **"deploy a new version"**, "cut a release", "publish a new version",
or anything equivalent, follow the **`/deploy`** command in
[`.claude/commands/deploy.md`](.claude/commands/deploy.md).

Non-negotiable: **always confirm the version number with the user via `AskUserQuestion`
before tagging** — propose a recommended semver bump from the latest tag, but never tag
without their explicit choice.

Release mechanics in brief:
- Pushing a `vX.Y.Z` tag triggers the **"Build & Release"** GitHub Actions workflow, which
  builds `FolderSync.app` and publishes a GitHub Release with a `FolderSync-X.Y.Z.zip` asset.
- `main` is protected: land changes via a PR, and merges require the **"Build & Test"** check
  to pass (`gh pr checks <n> --watch` then `gh pr merge <n> --merge`).
- Tag against `origin/main`: `git tag -a vX.Y.Z origin/main -m "FolderSync X.Y.Z"`.

## App facts
- Native macOS SwiftUI app, built with SwiftPM via `./build.sh` (no full Xcode needed).
- Repo: `wouterjanssens/FolderSyncForMac`. Public.
- In-app updater (in `Sources/FolderSync/Updater.swift`) checks the `releases/latest`
  redirect and applies updates via a detached helper that swaps the bundle and relaunches.
  Reliable from **v1.4.1+**; older builds need a one-time manual install into `/Applications`.
