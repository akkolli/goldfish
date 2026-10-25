# Goldfish repository

`main` is the authoritative committed Goldfish codebase. Before changing, building or installing, inspect `git worktree list`, the current HEAD, and the main checkout's status. Uncommitted main changes are not included automatically in another worktree. Resolve differing checkouts before making claims about the latest app.

Sources are in `Sources/Goldfish`; Swift tests are in `Tests/GoldfishTests`; build-tool tests are in `Tests/BuildTools`. Keep Goldfish in the package, executable, bundle and visible UI. New storage, bundle, encryption, Keychain, archive and backup identities use Goldfish. Old identities belong only in `GoldfishMigration` and its import tests; preserve backwards reading and transactional migration, never silently discard older history.

Quit Goldfish before clipboard tests. Run `scripts/check.sh` before committing. Use `scripts/install-macos-app.sh` to install clean current main; never install an app solely because its filename says Goldfish. Verify its embedded BuildInfo.json and the running executable path. Build guards must reject stale checkouts, changed inputs and dirty installs. `--allow-dirty` is for explicit development previews.

`codex/legacy-goldfish-refactor` preserves older reductions without the Goldfish redesign. It is an archive, not the production baseline. Preserve that history, and port any useful changes deliberately with behavior and UI parity checks.
