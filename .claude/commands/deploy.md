---
description: Cut and publish a new FolderSync release (asks for the version number)
argument-hint: "[version, e.g. 1.5.0 — optional; you'll be asked if omitted]"
---

You are cutting a new release of **FolderSync** (repo `wouterjanssens/FolderSyncForMac`).
A GitHub Actions workflow named **"Build & Release"** builds the app on a macOS runner and
publishes a GitHub Release with a `FolderSync-<version>.zip` asset whenever a `v*` tag is
pushed. Your job is to get `main` into the right state, pick the version **with the user's
explicit confirmation**, tag it, push it, and verify the release published.

Requested version (may be empty): `$ARGUMENTS`

Follow these steps in order. Use the Bash tool for all git/gh commands.

## 1. Survey the current state
- `git fetch origin --quiet --tags`
- Latest released tag: `git tag --sort=-v:refname | head -1`
- Unreleased commits: `git log --oneline <latest-tag>..origin/main`
- Uncommitted local changes: `git status --short`
- Open PRs: `gh pr list --state open --json number,title,headRefName`

## 2. Make sure what should ship is on `main`
- If there are **uncommitted changes** that are the intended fix/feature, surface them to the
  user, get confirmation, then commit on a branch and open a PR to `main` (do **not** push
  straight to `main` — the base branch is protected).
- If there are **open PRs** that should be part of this release, confirm with the user, then
  merge them (see merge rules below).
- To merge a PR: it requires the **"Build & Test"** check to pass first. Wait for it with
  `gh pr checks <num> --watch`, then `gh pr merge <num> --merge`. (Repo has no auto-merge;
  `--admin` is a last resort only if the user asks.)
- If `main` already contains exactly what should ship and there are no unreleased commits,
  tell the user there is nothing new to release and stop unless they confirm a re-tag.
- Always `swift build -c release` to confirm it compiles before tagging if you committed
  anything in this run.

## 3. Decide the version number — ALWAYS ASK
Compute a recommended next version from the latest tag using semver:
- bug-fix-only changes → **patch** bump (x.y.Z)
- new feature, backwards-compatible → **minor** bump (x.Y.0)
- breaking change → **major** bump (X.0.0)

Then **always** call `AskUserQuestion` to confirm, even if `$ARGUMENTS` contained a version
(treat that as the pre-filled recommendation). Offer the recommended bump first (labelled
"(Recommended)"), plus the other plausible bumps. Do not tag until the user has chosen.

## 4. Tag and push
With the confirmed version `X.Y.Z`:
- `git tag -a vX.Y.Z origin/main -m "FolderSync X.Y.Z"`
- `git push origin vX.Y.Z`

## 5. Watch the build and verify
- Find the run: `gh run list --workflow="Build & Release" --limit 1 --json databaseId,status,headBranch`
- Watch it: `gh run watch <databaseId> --exit-status`
- Verify the release: `gh release view vX.Y.Z --json name,url,assets,isDraft`
  — confirm it is not a draft and has the `FolderSync-X.Y.Z.zip` asset.

## 6. Report
Give the user the release URL and a one-line summary of what shipped. If the user is on an
older installed build, remind them: in-app update works from **1.4.1+**, otherwise a one-time
manual install into `/Applications` (not run from Downloads) is needed.

Be concise in your running commentary; do the work, surface decisions that need the user, and
report the result.
