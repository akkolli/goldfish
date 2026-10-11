# Goldfish

Goldfish is a native macOS clipboard manager with searchable vertical and horizontal shelves. It remembers text, code, colors, links, images, rich text, files, PDFs, audio, and video. Pinboards and pinned clips survive ordinary history expiry. Cards support preview, original-format or plain-text copy/paste, multi-selection, editing, renaming, drag-and-drop, and deletion Undo.

Goldfish was previously named ClipBored. Existing storage, preferences, bundle identifier, Keychain service, and archive identities remain compatible. Capture starts only after explicit first-run setup; automatic paste permission is optional. History and managed attachments are encrypted locally. Portable archives are unencrypted, and optional iCloud whole-history backup requires an entitled build.

See the [user guide](docs/QUICK_START.md) for controls and shortcuts, [interface specification](docs/UI_DESIGN.md) for layout and accessibility behavior, and [security notes](docs/SECURITY.md) for protections and limitations.

## Develop and verify

Requirements: macOS 13+, Xcode 16+ command line tools with the macOS 15+ SDK, and Python 3.9+. Goldfish uses Swift Package Manager, AppKit, Carbon, SQLite, and system frameworks, with no external packages.

`main` is authoritative. Inspect all worktrees, HEAD, and the main checkout's status before changing, building, or installing. The legacy refactor branch is preserved history, not the production baseline. Quit Goldfish before clipboard tests. Native focus tests require an unlocked Mac; `GOLDFISH_TEST_SCREEN` selects the display for interface tests.

```bash
./scripts/check.sh
python3 scripts/project-metrics.py
./scripts/build-macos-app.sh --allow-dirty
```

Checks run Swift and build-tool tests, documentation references, shell syntax, whitespace, release packaging, signature verification, and executable/bundle size gates. Metrics count every maintained text file, including tests, documentation, scripts, configuration, text assets, comments, and blanks; binary assets are reported separately. Generated output is excluded. `--max-lines 9999` enforces the size target.

Development previews are marked dirty and cannot be installed through the guarded installer. After checks and committing to clean current main:

```bash
./scripts/install-macos-app.sh
```

The installer rebuilds, verifies provenance and signing, preserves the previous app, installs to `/Applications/Goldfish.app`, and launches that copy. Verify its embedded `BuildInfo.json` and running executable path. A Goldfish filename alone does not establish that a build is current.

## Navigate the project

Application code is in `Sources/Goldfish`: `app` wires services; `config` defines defaults and limits; `models` holds values and preferences; `services` owns capture, data, and transfers; `views` owns native UI; `extensions` contains small platform helpers; `resources` contains bundle metadata and icons. Swift tests are in `Tests/GoldfishTests`; packaging/provenance tests are in `Tests/BuildTools`.

Start with [component ownership](docs/ARCHITECTURE.md) and [contributing](CONTRIBUTING.md). Use the [release procedure](docs/RELEASE.md) and [manual checks](docs/SMOKE_TEST.md) before distribution. The [documentation index](docs/README.md) links current guides, [roadmap](docs/ROADMAP.md), and preserved design evidence.

GPL-2.0-only; see [LICENSE](LICENSE).
