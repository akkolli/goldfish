# Goldfish

Goldfish is a native macOS clipboard manager with keyboard-first vertical and horizontal clipboard shelves. It captures local clipboard history and makes clips easy to find, preview, organize, copy, paste, pin, and delete. It runs as a dockless menu-bar utility by default, with an optional Dock icon.

Previously named ClipBored. Goldfish retains the existing bundle identifier, preferences, history folder, Keychain service, and archive format so the rename preserves access to saved data. Application sources live in `Sources/Goldfish` and Swift tests in `Tests/GoldfishTests`; the executable and packaged app are `Goldfish` and `Goldfish.app`.

The project is intentionally dependency-light: Swift Package Manager, AppKit, Carbon hotkeys, SQLite, and system frameworks only.

## Features

- Persistent search with named destinations, independent content-type filters and sorting, plus source-app/date suggestions and one-click reset
- Icon navigation: All clips, Pinned, and user-created Pinboards stay available during zero-result searches; the vertical layout places content-type icons in an attached notch
- Content-sized cards with copied text, image/document previews, source icons, colored type headers, and character counts. The vertical grid pairs short clips and gives long clips a full row; the horizontal rail uses the display width. Hover and selection keep layout stable
- Shared keyboard and context-menu actions, outcome announcements, deletion Undo, and capture pause/resume
- Optional soft copy/paste sounds with volume control, no overlap, and quieter rapid repeats
- Compact, Standard, and Wide shelf widths; left/right placement; larger clip text; semantic light/dark colors; reduced effects and stronger contrast when requested by macOS
- Short shelf, menu, and card transitions that honor the macOS Reduce Motion accessibility setting
- Compact first-run welcome with a card-shelf preview, shortcut chooser, and optional automatic-paste permission. Advanced preferences stay in Settings; capture starts after setup and does not backfill earlier copies
- A menu-bar status menu with capture state, history count, settings, manual or timed pause/resume, and quit
- Global and panel shortcuts:
  - The configured open shortcut toggles the clipboard shelf
  - `Command + ,` opens settings
  - `Command + F` focuses search
  - `Command + 1` through `Command + 9` pastes the numbered visible card; add `Shift` to use plain text
  - `Return` pastes the selected clip; `Shift + Return` or `Command + Shift + V` uses plain text
  - `Command + C` copies the selected clip or selected clips
  - `Command + N` creates a text clip without touching the clipboard; `Command + P` pins the current clip
  - `Command + E` edits the selected text or code clip, and `Command + R` renames it
  - `Delete` removes selected clips, and `Command + Z` restores the last deleted batch
  - `Command + G` shows a filtered result in the full clipboard history
  - `Command + O` opens the selected link, file, or media clip when possible
  - `Shift + Command + N` creates a Pinboard collection
  - `Command + Left` and `Command + Right` move between collections
  - `Command + Up` and `Command + Down` jump to the first or last visible clip
  - `Command + T` pauses or resumes clipboard capture
  - `Command + A` selects the visible list from a focused card; Shift-modified navigation extends a range
  - `Space` or `Command + Y` previews the selected card when the focused search field is empty
- Keyboard-focusable cards and navigation icons with type-to-search, visible focus chrome, VoiceOver descriptions, context menus, arrow-key card navigation, and direct category navigation
- Clipboard history for text, code, colors, URLs, images, audio, video, RTF/HTML rich text, PDFs, and file references
- Immediate cards with previews loaded asynchronously. Image, link, document, and movie thumbnails fill in without blocking search, selection, or scrolling
- Previews that stay attached to the shelf: an ephemeral browser for links and native Quick Look for files and media. Closing a preview restores the selected clip; dismissing the shelf closes its previews
- Independent-token and structured search, including `app:Safari`, `type:image,pdf`, `device:MacBook`, `pinboard:"Client Work","Read Later"`, and `date:2026-06-30`
- Named Pinboards, including empty Pinboards, with batch collection assignment from the context menu, Pinboard context menus for editing/export, drag-to-Pinboard assignment, and durable retention
- Searchable custom clip titles that do not alter the copied payload
- Multi-selection with original-format or plain-text batch copy and paste
- SQLite persistence with bounded history, time-based retention, pinned-item and Pinboard retention, and encrypted app-managed payloads
- A bounded, disposable thumbnail cache with asynchronous loading and byte/file-count pruning; clearing it never removes restorable full images
- Portable local archive export/import for history, Pinboards, and managed attachments, bounded to 128 MB; external file references stay path-based
- Optional whole-archive iCloud backup and restore for signed builds with an iCloud entitlement
- A redesigned, resizable Settings window with a stable sidebar for `General`, `Shortcuts`, `Capture`, `Privacy`, `Performance`, and `Data`. Each page is vertically scrollable and keeps controls aligned at narrow window sizes
- Settings for shelf layout, side, width, and text size, retention, history length, sort order, cache limit, capture responsiveness, an ignored-app picker with advanced rules, shortcut recording, and existing privacy/startup controls
- Local-first storage, with likely-secret exclusion enabled for fresh profiles and iCloud backup disabled by default

[Current design, architecture, and developer guides](docs/README.md).

## Requirements

- macOS 13 or newer
- Xcode 16 or newer command line tools with the macOS 15 SDK or newer
- Python 3.9 or newer for build provenance and verification

## Build

```bash
swift test
./scripts/build-macos-app.sh
./scripts/install-macos-app.sh
```

Use the clean, committed `main` checkout for installation and quit Goldfish first. `scripts/install-macos-app.sh` builds, verifies, backs up the existing app, installs to `/Applications/Goldfish.app`, and launches it. Stale checkouts, uncommitted main changes in another checkout, dirty installs, and source/provenance mismatches fail before replacement. Each bundle records its commit, checkout, source hash and build time in `Contents/Resources/BuildInfo.json`.

The build script packages `build/Goldfish.app`, strips the executable, applies and verifies an ad-hoc hardened-runtime signature, and enforces a 2 MiB per-architecture executable gate. Bundles get a fixed additional 1 MiB allowance for the modern icon's appearance assets (3 MiB local / 5 MiB universal). Xcode 26+ compiles the layered icon; older SDKs use the bundled full-resolution `.icns` fallback.

## Development

For development, `./scripts/build-macos-app.sh --allow-dirty` produces a preview that the installer rejects. Run the full local validation with Goldfish stopped:

```bash
./scripts/check.sh
```

Useful commands:

```bash
swift test -q
./scripts/build-macos-app.sh
./scripts/release-macos-app.sh
./scripts/idle-soak-report.sh 900
python3 scripts/project-metrics.py
```

[Architecture and component ownership](docs/ARCHITECTURE.md) describes where each responsibility lives. The metrics script counts all maintained text, including tests, documentation, scripts, configuration, and text assets. It also reports app/test Swift separately and binary asset sizes. Generated output is excluded. Use `--max-lines 9999` to enforce the under-10,000-line target.

For app-level behavior that cannot be fully covered by unit tests, run [docs/SMOKE_TEST.md](docs/SMOKE_TEST.md). For distribution builds, see [docs/RELEASE.md](docs/RELEASE.md).

Project layout:

- `Sources/Goldfish/app` - app entry point and service wiring
- `Sources/Goldfish/config` - defaults and power/size guardrails
- `Sources/Goldfish/extensions` - small AppKit/Foundation helpers
- `Sources/Goldfish/models` - clipboard item and settings models
- `Sources/Goldfish/resources` - app bundle metadata and icon assets
- `Sources/Goldfish/services` - capture, persistence, cache, shortcuts, paste, diagnostics, and privacy filters
- `Sources/Goldfish/views` - panel, onboarding, preview, and settings UI
- `Tests/GoldfishTests` - focused behavior tests for capture, persistence, search, paste, and settings decisions
- `docs` - architecture, security, release, smoke-test, and roadmap notes

## Privacy And Security

Goldfish does not use telemetry. Clipboard history is stored locally under Application Support unless iCloud Backup is explicitly enabled in a signed build with an iCloud entitlement. User-triggered link previews load the selected web page in an ephemeral built-in WebKit view.

Textual SQLite fields, full images, thumbnails, audio clips, video clips, rich text sidecars, and PDF attachments are encrypted with AES-GCM. Goldfish reuses legacy owner-only fallback keys when present, but does not create a competing fallback after an uncertain Keychain write. Production capture pauses if no stable key is available instead of persisting plaintext. Confidential and transient clipboard markers are always excluded. Portable archive exports and iCloud backup archives are not encrypted by Goldfish, so treat them as sensitive backups. Temporary decrypted preview files are cleared on launch, cache/history clear, and quit. See [docs/SECURITY.md](docs/SECURITY.md) for details and responsible disclosure.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The current roadmap is in [docs/ROADMAP.md](docs/ROADMAP.md).

## License

GPL-2.0-only. See [LICENSE](LICENSE).
