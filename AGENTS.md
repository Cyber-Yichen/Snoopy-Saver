# Snoopy Agent Harness

These instructions apply to the entire repository. They constrain future coding agents; they are not end-user documentation. System, developer, and current user instructions always take precedence.

## 1. Scope and hard boundaries

- The active repository is this Git worktree. On the owner's Mac it is normally `/Users/yichen/Documents/Git/Snoopy`.
- Never read, copy, compare, or derive content from these archived worktrees unless the current user explicitly reverses this rule:
  - `/Users/yichen/Documents/Git/Snoopy-archive-20260711`
  - `/private/tmp/SnoopyScreenSaver-derived-archive-20260711`
- Do not inspect `Hermes`, `SecretKey.csv`, SSH keys, COS credentials, server credentials, or unrelated repositories unless the current request explicitly requires that exact access.
- Do not upload to a server, CDN, COS, GitHub Release, or any other external service without explicit authorization in the current request.
- Never add Apple/Peanuts media or packaged savers to Git. This includes `.mov`, `.heic`, `.saver`, `LocalAssets/`, `Releases/`, `.build/`, extracted simulator packages, and encrypted media archives.
- The public repository may contain implementation, validation, and media-transformation code, but not simulator extraction/downloader code for obtaining Apple assets.

## 2. Mandatory start sequence

Before reading broadly or changing files:

1. Read `.agents/project-state.json`.
2. Run `Scripts/agent_preflight.sh read` for investigation-only work, or `Scripts/agent_preflight.sh change` before an implementation task.
3. Inspect `git status --short --branch`, the current branch/upstream, and relevant diffs. Preserve all user-owned dirty changes.
4. Confirm whether the request is diagnosis-only or authorizes implementation. Do not turn a diagnosis request into a code change.
5. Identify the media provenance involved: Apple original 4K, Apple original 1080p, locally transcoded 1080p, or CDN cache. Never describe one as another.

If preflight fails, stop mutations and resolve the reported branch, media, version, or toolchain problem first. Do not bypass a gate by weakening the gate script. When the current user explicitly changes a frozen contract, update `AGENTS.md`, `.agents/project-state.json`, the implementation, and its validator together as one intentional change.

## 3. Branch and version discipline

- `main` is the stable published line. Treat it as protected and do not commit product changes directly to it.
- `beta` is the active development and stabilization line for the standard saver.
- Promotion direction is `beta` -> `main`. Promotion, merge, or release requires explicit current-user authorization.
- If a change task starts on `main`, switch to `beta` before editing unless the user explicitly authorizes another branch strategy. Do not create ad-hoc branches for routine work.
- Never force-push, rewrite a published branch, move a tag, delete a branch/tag, or reset another person's work without explicit approval.
- Do not merge `beta` into `main`, publish a release, or create/update a release tag unless the current user explicitly requests that exact promotion or release action.
- Do not change `CFBundleShortVersionString` or `CFBundleVersion` as incidental cleanup. A version/build change requires explicit user intent and must be reflected in `.agents/project-state.json` in the same commit.
- Before pushing, state the target branch. Media and `.saver` files must remain ignored. Push only the intended branch.

## 4. Product behavior that is currently frozen

Unless the current user explicitly asks to change one of these behaviors:

- Cold start remains 50% IdleScene and 50% ActiveScene.
- IdleScene duration remains randomized between 20 and 60 seconds.
- Playback has no sound, clock, or text overlay.
- The standard saver plays bundled media. There are no separate 1080p or CDN download builds.
- IdleScene preserves alpha, palette background, halftone overlay, character/visitor planes, continuous phase playback, and aspect-ratio-safe layout.
- ActiveScene/IdleScene transitions retain the official five styles where metadata covers them and use dissolve only as fallback.
- Date, routine, weather, recency/frequency decay, and highest-score tie randomization remain part of selection.
- Do not collapse multi-layer IdleScene into a precomposited flat video.

## 5. Bundle identity contract

| Build | Bundle ID | Objective-C principal class | Swift module | Media policy |
| --- | --- | --- | --- | --- |
| standard / 4K | `local.snoopy.ScreenSaver` | `SnoopyScreenSaverView` | `SnoopyScreenSaver` | bundled only |

Changing an identifier requires updating the relevant product metadata, build script, tests, installer, and project state together.

## 6. Tool and environment routing

- Run `/Users/yichen/.local/bin/codex-vm project-info "$PWD"` before compilation or tests when that helper exists.
- Keep Xcode, Swift/macOS builds, AVFoundation/ImageIO alpha work, signing, `.saver` packaging, and GUI/runtime smoke tests on the Mac.
- Route Linux-compatible FFmpeg conversion, disposable downloads, package installation, and non-macOS builds through the registered `codex-linux` VM. Do not create host package caches or host dependency trees for those tasks.
- Use existing scripts and project-local `.build/` output. Do not install Homebrew merely to complete this project.
- Use `apply_patch` for source edits. Preserve unrelated changes and avoid destructive Git commands.

## 7. Verification routing

Every code change must pass `Scripts/agent_check.sh quick` before handoff. Add the following gates according to the touched behavior:

| Change area | Additional required gate |
| --- | --- |
| selection, themes, dates, weather, scoring, catalog | `Scripts/agent_check.sh theme [PATH_TO_RESOURCES]` |
| alpha/IdleScene media pipeline | `Scripts/agent_check.sh runtime PATH_TO_SAVER` plus an actual IdleScene screenshot |
| playback lifecycle, transitions, performance, memory | `Scripts/agent_check.sh runtime PATH_TO_SAVER` |
| bundle ID/class/module or build scripts | quick gate's bundle identity, architecture and signature checks |
| release candidate | all relevant gates, universal architecture, strict code-sign verification, version/build check, and tracked-media audit |

For transparency regressions, test the final bundle with real `AVPlayerLayer`/full IdleScene rendering. For performance regressions, report scene-switch count, peak RSS, root-layer cleanup, and whether helper processes retained stale bundles.

## 8. Installation and runtime diagnostics

- Before blaming a movie, inspect the actual file opened by `legacyScreenSaver` with `lsof` and check every installed Snoopy bundle's ID/class/build.
- macOS may retain unloaded or deleted `.saver` bundles in the helper process. Restart `legacyScreenSaver`/`ScreenSaverEngine` after replacement; a full system reboot should not be the primary remedy.
- Do not install or remove a user's saver during diagnosis unless installation/replacement is in scope.
- Logs must not contain credentials, query tokens, or precise location data.

## 9. Handoff requirements

At completion, report:

- branch and commit (and whether it was pushed);
- exact files/areas changed;
- tests run and their concrete outcomes;
- artifact paths and whether they are ignored by Git;
- media provenance used in visual tests;
- anything not tested or any remaining risk.

Do not claim completion from compilation alone. Do not claim an official Apple file was tested if the tested file was transcoded.
