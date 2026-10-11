# Goldfish: content and workflow review, September 22

These native AppKit renders use synthetic content and isolated preferences. They contain no customer history or Paste artwork. Every screen has light and dark variants.

- `shelf-light.png` / `shelf-dark.png`: 420 pt vertical shelf with visible text, links and imagery.
- `shelf-compact-*` / `shelf-wide-*`: 336 and 540 pt shelf widths.
- `shelf-large-text-*`: larger text, including complete short paragraphs.
- `shelf-focused-*` / `shelf-multiple-*`: focus and selection without resizing cards.
- `shelf-link-*`, `shelf-image-*`, `shelf-code-*`, `shelf-color-*`, `shelf-documents-*`, `shelf-short-copy-*`: representative content and honest unavailable-preview states.
- `new-clip-editor-*` / `new-pinboard-*`: attached editors with validation and cancellation.
- `filtered-new-copy-*`, `capture-paused-*`, `search-empty-*`: recovery states.
- `settings-0-*` through `settings-5-*`: General, Shortcuts, Capture, Privacy, Performance and Data.
- `welcome-*`: first-run introduction with the same vertical card language.

Live checks are recorded in [the implementation review](../README.md). Offscreen renders do not measure frame pacing or replace physical VoiceOver, multi-display, and older macOS testing. The previous September 21 fixtures remain as a historical record.
