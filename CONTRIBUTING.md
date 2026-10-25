# Contributing

Thanks for working on Goldfish. The project is optimized for a small binary, low idle power, private local storage, and native macOS ergonomics. Changes should protect those constraints.

Please follow the [code of conduct](CODE_OF_CONDUCT.md). Use [discussions](https://github.com/akkolli/goldfish/discussions) for broad proposals and [issue forms](https://github.com/akkolli/goldfish/issues/new/choose) for actionable reports. Never attach real clipboard databases or keys. Security reports belong in the [private channel](SECURITY.md). Contributions are licensed under GPL-2.0-only; no CLA is required.

## Local Setup

Start with `git worktree list` and compare the current checkout with `main`. The latest Goldfish code is committed on `main`; `codex/legacy-goldfish-refactor` is an archived experiment without the redesign. Do not merge or ship it as current Goldfish.

Quit Goldfish before running tests: checks require a stopped app and fail if process inspection is unavailable. Capture and transfer tests use private named pasteboards and isolated storage; they do not replace your clipboard.

```bash
swift test
./scripts/build-macos-app.sh --allow-dirty
open build/Goldfish.app
```

Commit verified work before using `./scripts/install-macos-app.sh`. Builds embed provenance, installation requires clean current `main`, and the build guard checks other worktrees for unpublished main changes.

Run the full local check before opening a pull request:

```bash
./scripts/check.sh
```

## Engineering Guidelines

- Prefer AppKit, Foundation, Carbon, SQLite, and system frameworks over third-party dependencies.
- Keep the release app small. If a dependency or framework is needed, document the feature value and size impact.
- Keep capture local and telemetry-free. Networking is limited to explicit web previews and optional iCloud backup; discuss any expansion before implementing it.
- Avoid storing new classes of sensitive data. If capture behavior expands, add tests and update `docs/SECURITY.md`.
- Keep idle work bounded. Polling, timers, file scans, and cache purges should have clear caps or backoff behavior.
- Add tests for persistence, pruning, sensitive filtering, shortcut parsing, pasteboard behavior, and search/sort changes.
- Prefer behavior-level tests. Use the smoke checklist for visual layout instead of adding production debug accessors for private UI details.
- Extend `GoldfishWorkflowTests` when a user journey crosses capture, storage, search, transfer, shelf, or Settings. Keep focused tests for failure paths and formats that the workflow tests cannot safely exercise.
- Format application Swift consistently with `xcrun swift-format format --configuration .swift-format --in-place --recursive Sources/Goldfish`.
- Put card actions in `ClipCommand` and its shared handler; keep ordinary settings reads/writes together in a typed binding.
- Keep geometry, appearance, and field-editor behavior in their named components. Remove obsolete paths when a design is retired.
- Report source and release size with `python3 scripts/project-metrics.py`; do not count cache removal as code reduction.
- Keep UI native and compact. This is a utility, not a marketing surface.

## Pull Request Checklist

- `swift test -q` passes.
- `./scripts/check.sh` passes, including its marked development release build.
- The release executable remains under the size gate printed by the build script.
- Security or privacy behavior is unchanged or documented.
- User-facing behavior is covered by tests or a manual verification note.
- Documentation is updated when commands, settings, storage, or permissions change.

## One-developer workflow

Use Python 3.9+ and Xcode 16+ with the macOS 15+ SDK. The [documentation index](docs/README.md) separates current guidance from historical reports. Keep data mutations in `HistoryStore`, shelf filter transitions in `ShelfState`, and archive/backup serialization in `DataCoordinator`; views present outcomes rather than owning another persistence path. Prefer batch APIs and shared test fixtures. Preserve behavior scenarios and assertions when merging tests.

Before installation or release, run `scripts/check.sh`, commit on a branch that includes current main, and fast-forward a clean main checkout. Publish main and preserve the archive branch on the working remote. GitHub macOS CI runs the same checks. Never force-push production or merge the legacy archive as the baseline. Ignored local `plan/` notes and generated artifacts are not shared project state.
