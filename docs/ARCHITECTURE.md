# Architecture

Goldfish is a single-process AppKit utility built with Swift Package Manager. UI, capture, persistence, preview generation, and paste orchestration stay in-process. SQLite commits run on a serial storage queue and publish state only after success. Thumbnail loading, archive operations, image rotation, and OCR use bounded background queues; UI state and completion feedback return to the main thread.

## Runtime Shape

- `GoldfishApp` creates `NSApplication`, installs `AppDelegate`, and starts the run loop.
- `AppDelegate` wires services, menu-bar commands, settings observers, and global shortcuts.
- `ClipboardMonitorService` watches `NSPasteboard.changeCount` on a utility queue with adaptive active/idle polling intervals selected by the Performance setting.
- `ClipboardStore` owns the main-thread in-memory item list and serializes all SQLite work on one persistence queue. Background archive operations take main-thread snapshots or apply imports on the main thread.
- `ClipboardCacheService` stores durable encrypted full images separately from disposable encrypted thumbnails and maintains a small in-memory cache.
- `ClipboardDataCoordinator` serializes local export/import and automatic/manual backup work. Disabling backup invalidates queued work and authorizes publication under a lock immediately before the atomic archive write.
- `ClipboardShelfState` owns atomic search, destination, and content-filter transitions; its actions preserve legacy preference raw values.
- `ClipboardCloudSyncService` resolves the private iCloud ubiquity container and pushes or restores one portable backup archive only when backup is enabled.
- `ShortcutManager` registers the configured system-wide shelf hotkey. The Settings binding is handled by the shelf's local key monitor and is never registered globally.
- `ClipboardPanelController` owns one active preview and guarded animation completions for shelf lifecycle, current-screen placement, left/right frame planning, target-app tracking, and show/hide/reflow animation.
- `ClipboardPanelSearchEngine` owns query normalization and parsing, structured-filter matching, and cached searchable documents.
- `ClipboardPanelViewModel` owns the selected destination and content filter, indexed search/sort results, selection, copy/paste, pinning, Pinboards, deletion, and thumbnail request coalescing. One typed change stream publishes model events on the main thread; item events follow selection reconciliation. A visible-items revision identifies each result update; pointer selection does not rebuild the result set.
- `ClipboardPanelView` owns shelf layout, viewport virtualization, and editor orchestration. `ClipboardShelfControls` owns destination/type/order controls and action/capture feedback. `ClipboardSearchControl` owns the search field, clear button, field-editor delegate, and focus appearance.
- `ClipboardCardConfiguration` is the immutable input to rendering and reuse. `ClipboardCardCommand` routes panel shortcuts, card keys, context menus, and VoiceOver through one shelf handler and defines card selection policy; `ClipboardCardNavigation` shares the focused-card navigation handler. `ClipboardCardLayout`, `ClipboardCardTextLayout`, and `ClipboardVerticalGridLayout` own geometry; `ClipboardCardPreviewView` draws content; `ClipboardItemCardView` handles interaction.
- `ClipboardShelfStyle` and `ClipboardShelfMotion` own shared appearance and reduced-motion policy. The scroll view handles overflow fades and wheel direction; the scroller handles its native thumb.
- `ClipboardSoundService` lazily synthesizes two short cues, prevents overlap, and softens bursts. Captures and explicit copies use the copy cue; the paste cue runs only after successful keyboard delivery. Both are opt-in.
- `NativeUI` constructs ordinary AppKit stacks and labels with explicit local styling. `ClipEditorPanel` and its shared surface provide attached-window construction; one attach/detach path inherits shelf privacy, ownership, and space membership.
- `ClipTextEditorController` owns the attached editor and draft validation. `ShortcutRecorderButton` and `IgnoredAppsEditor` provide native key recording and application selection in Settings.
- `ClipboardItemCardContentFormatter` derives card titles, metadata, URL/file summaries, metrics, symbols, and accent colors independently from AppKit view state.
- `LinkPreviewWindowController` opens user-selected HTTP(S) links in an ephemeral WebKit preview window.
- `OnboardingWindowController` introduces the shortcut and optional Accessibility permission. Closing defers setup. Only Start completes onboarding; AppDelegate guards every shelf entry point and clipboard polling until then.
- `SettingsWindowController` presents six settings pages and owns operations requiring side effects. `SettingsControlBinding` keeps each ordinary setting's read/write pair together with a typed key path. `SettingsPageView` owns shared section appearance and scroll geometry.

## Capture And Presentation Flow

1. The monitor notices a pasteboard change.
2. Capture rules check paused state, ignored frontmost apps, allowed content kinds, and likely-sensitive text/URL exclusion. Managed payloads above 64 MB are rejected.
3. Pasteboard content is normalized into a `ClipboardItem`; local Vision OCR runs when image-label search is enabled.
4. The store deduplicates, preserves pinned and Pinboard-assigned items, enforces retention/length limits, and commits the mutation before publishing it. File cleanup follows a successful transaction; failures leave the prior state and attachments intact.
5. The search engine parses and matches the query while caching normalized item documents. The view model maintains destination/Pinboard indexes and caches result ordering. The current UI has one destination at a time; the retired collection-chip union mode has been removed.
6. An independent content-type filter and selected ordering apply within the destination. The view materializes only nearby cards: an adaptive two-column grid with wide cards in the vertical shelf, or a single horizontal rail.
7. Selection dictionaries are built once after filtering and sorting. Type counts are cached by result revision; hover checks that revision in constant time and changes emphasis without rerunning card layout.
8. The card formatter uses the shared kind presentation (label, symbol, search terms, accent) and derives display content without owning view state, and cards render immediately with a fallback presentation. Preview thumbnails load on a bounded operation queue; identical in-flight requests share work, and a still-relevant card is replaced in place on the main thread when its image arrives.

## Shelf Interaction Model

The shelf supports two layouts on the selected display:

- Vertical: an attached content-type notch, search/actions aligned with the cards, an icon destination row, and a content-sized grid. Short clips can share a row; long clips span it.
- Horizontal: a single control row and a card rail spanning the display width, with screen-relative edge margins.
- Both float above the Dock, use the same transparent surface, and keep card geometry fixed during hover and selection. The native scroller has a separate lane. Overflow fades belong to the clip view rather than opaque overlays.
- The new-clip and clear-history buttons toggle anchored panels. Presenters coordinate so competing panels close or suspend drafts; dismissing the shelf closes its attached UI. Pinboard creation/editing uses the same compact surface.
- Keyboard and context-menu actions provide copy/paste, plain-text variants, selection, pinning, editing, and deletion undo. Capture pause lives in Settings and the status menu. There is no bottom action bar.
- Semantic colors and custom surfaces respond to appearance, Increase Contrast, and Reduce Transparency. Reduce Motion disables the relevant transitions.

General settings offers Compact, Standard, and Wide sizing, larger clip text, left/right placement for the vertical shelf, and layout selection. Compact/Standard/Wide set the vertical reading width or horizontal card size. Escape clears a nonempty search first, then closes the shelf. Menu-bar click and the global shortcut toggle it.

## Settings UI

Settings uses a stable sidebar backed by a borderless `NSTabView`. The transparent titlebar spans the full content area without an opaque strip:

- `General` - history, shelf layout/size/text, copy/paste sounds and volume, launch, and menu-bar/Dock presence
- `Shortcuts` - a system-wide open-shelf binding and a pane-local open-settings binding
- `Capture` - pause state, content kinds, image-label search, likely-secret exclusion, ignored apps, and capture status
- `Privacy` - local-data behavior, screen-capture hiding, Accessibility permission, and paste status
- `Performance` - adaptive polling profile and thumbnail-cache cap
- `Data` - iCloud whole-archive backup/restore, local archive import/export, storage location, and destructive clears

Each tab is a top-aligned document inside its own vertical scroll view. The window has a practical minimum size and no horizontal scrollers. Shortcut recording commits only a valid combination; cancellation or closing preserves the old binding. Common settings changes update their controls without rebuilding the window; expensive cloud status checks are cached across unrelated refreshes.

## Persistence And Privacy Boundaries

History is stored in:

```text
~/Library/Application Support/ClipBored/history.sqlite
```

Goldfish keeps the pre-rename storage directory, `com.local.clipbored` bundle/defaults identity, Keychain service, encryption marker, pasteboard type, `.clipboredarchive` format, and existing iCloud archive location. These are compatibility identifiers, separate from `AppConfiguration.appName`. New export filenames and visible UI use Goldfish.

Restorable full images are stored under `images/`, disposable thumbnails under `thumbnails/`, and restorable audio, video, rich-text, and PDF payloads under `attachments/`. Legacy `images/thumb-*` files remain recognized for safe pruning. Legacy JSON import remains for migration from early builds.

Portable `.clipboredarchive` files preserve item metadata, Pinboards, and decrypted bytes for app-managed sidecars so another Mac can re-cache them with its own storage paths and encryption key. External file references remain path-based. Archives are bounded to 128 MB. Optional iCloud backup uses the same unencrypted whole-archive format inside the app-private ubiquity container and is disabled by default; it is not conflict-aware sync.

The store uses one ordered column list for SQL reads and writes and one typed mapping for optional textual fields. Textual SQLite fields are encrypted and decrypted at the `ClipboardStore` boundary. Managed image, thumbnail, and attachment files are encrypted and decrypted at the `ClipboardCacheService` boundary. The key lives in Keychain when available; an existing legacy owner-only fallback is reused, but uncertain Keychain writes never create a competing key. Runtime `ClipboardItem` values remain plaintext in memory for search and clipboard operations. Opening encrypted media may create a temporary decrypted file; stale previews are cleared on launch, cache/history clear, and quit. Link previews are user-triggered and use a non-persistent WebKit data store; only an explicit user link activation may hand a custom scheme to another app.

## Size And Power Constraints

The release build intentionally avoids SwiftUI, Combine, Swift Concurrency, third-party packages, and bundled media. The shelf avoids continuous layout work, renders only cards near the viewport, coalesces preview requests, keeps card-thumbnail decoding off the main thread, and bounds both memory and disk caches. Clipboard monitoring uses change-count polling with selectable adaptive profiles rather than continuous file scans.

The build script uses `-Osize`, whole-module optimization, disabled reflection metadata, linker dead stripping, symbol stripping, and verified hardened-runtime signing. Size gates are 2 MiB per requested architecture. Local builds use the host architecture; release builds default to universal arm64/x86_64.

## Maintenance Boundaries

Keep capture and persistence out of views. Keep shared geometry and colors in their named components. Add a card operation to `ClipboardCardCommand` and its handler once, then invoke it from the relevant input surface. Each `Preference` declares its existing storage key, normalization, encoding, and change notification; mutations write only that key. Bind ordinary settings beside their control definitions; use controller commands for permissions, archives, and other side effects. Do not restore old UI modes or test-only production helpers to accommodate a retired design.

Run `./scripts/check.sh` for tests, a release build, signature verification, and size gates. Run `python3 scripts/project-metrics.py` for comparable line and byte counts (`--json` for scripts). Physical line counts include comments and blanks; app and test Swift are reported separately. The maintained-text total includes source, tests, documentation, scripts, configuration, and text assets, including new files awaiting commit and ignored compiler inputs. Git metadata, compiler caches, and generated output are excluded; binary assets are reported separately. `--max-lines 9999` fails when the under-10,000-line target is unmet. Design reference screenshots remain in `docs/`; they are not shipped.

Build artifacts in `.build/` and `build/` are disposable. After validation, `swift package clean` removes package intermediates while leaving `build/Goldfish.app` available. A cold rebuild recreates the cache. Keep the legacy storage and security identifiers above; they are compatibility boundaries, not naming debt.

## Data mutation contract

The store is the sole owner of durable history mutations. Callers propose changes on the main thread; one transaction writes changed rows and deletes removed rows before notifying observers. Failure returns an unsuccessful result and a visible storage warning. Bulk rename, assignment, deletion, and usage updates commit once. Imported attachments use fresh local storage IDs, never archive paths or live filenames; failed imports remove only their new files and leave collection preferences untouched. Existing Pinboards, including old default names, remain retained.

Tests inject named pasteboards and isolated cache/history directories. No automated test needs to replace the general clipboard. Compatibility identities remain `com.local.clipbored`, the ClipBored storage and Keychain names, the existing encryption marker, `.clipboredarchive`, and the existing cloud backup path.
