# Welcome to Goldfish

Goldfish is a local-first clipboard shelf for macOS 13 or later. The universal
build supports Apple Silicon and Intel Macs. Move the app to Applications before
enabling launch at login or granting Accessibility permission.

## Get started

1. Open Goldfish, choose a shortcut, and click Start using Goldfish. Paste permission
   is optional; all other preferences are in Settings. Only Start enables capture.
   Closing welcome defers setup; the menu bar or shortcut reopens it. Earlier copies are not backfilled.
2. Copy a few things in your usual apps.
3. Click the menu-bar icon or press your chosen shortcut. First-run setup offers
   Shift-Command-V; the alternate shortcut is Command-Option-V.
4. Type to search, use Up/Down to select, then Return to paste. Without Accessibility
   permission, Goldfish copies the clip instead; switch back to your app and press Command-V.
   Down Arrow from search enters the selected result. Escape clears a search first, then closes the shelf.

## Useful shortcuts

| Action | Shortcut |
| --- | --- |
| Search | Type, or Command-F |
| Preview | Space |
| Paste plain text | Shift-Return |
| Copy selected clips | Command-C |
| Quick paste / quick paste plain text | Command-1–9 / Shift-Command-1–9 |
| New text clip | Command-N |
| Open selected clip / show in All clips | Command-O / Command-G |
| Edit / rename | Command-E / Command-R |
| Pin / new Pinboard | Command-P / Shift-Command-N |
| Select several / select all | Command-click, Shift-click, Shift-arrow / Command-A |
| First / last clip; page through clips | Home / End; Page Up / Page Down |
| Previous / next destination | Command-Left / Command-Right |
| Pause / resume capture | Command-T |
| Undo deletion | Command-Z |
| Settings | Command-comma |

The destination icons above the vertical grid open All clips, Pinned, and your
Pinboards. The plus button or Shift-Command-N creates a Pinboard. Right-click a
clip for Add to Pinboard, original-format and plain-text copy/paste, selection
transfer, Open, Reveal in Finder, Quick Look, Rename, editing, image rotation/OCR,
capture exclusions, pinning, and deletion. Available commands depend on its type.
Drag clips into a Pinboard or another app. Right-click a Pinboard icon to edit its
name/color/icon, export it, or delete it. Deleting a Pinboard removes its clips
after confirmation. Pinned and Pinboard clips survive ordinary history expiry.

The pencil button toggles the text composer. The trash button offers 1 day, 1 week,
and All time cleanup; these keep pinned and Pinboard clips. Undo restores the most
recent clip deletion. Settings > Data has a separate confirmed full-data reset.
The current system clipboard is never cleared by history cleanup.

Search supports `app:Safari`, `type:image,pdf`, `pinboard:"Work"`, and
`date:2026-09-21`, combined with ordinary words. Destination, content type, and
sorting work independently. The content icons sit in the attached left notch;
the filter button offers dates and source apps, and the sort button toggles newest
and most used first. Reset clears search and filters. VoiceOver reports the visible
and total clip counts on this control.

New copies hidden by your current scope show a **Show new** notice; this clears
filters and selects the latest copy. Right-click the menu-bar icon for capture
status and pause/resume, including timed pauses. Settings > Capture also controls
capture. Settings > General offers three shelf sizes, larger text, left/right
placement, optional horizontal browsing, and optional copy/paste sounds. The
vertical shelf is the default; neither layout has a bottom action bar.

Text clips open in an attached editor. Command-Return saves; Escape cancels.
An unsuccessful save keeps your draft in the editor. Preview with Space; Escape or the
preview’s close button returns to the shelf. Clicking outside dismisses the shelf and
its preview. The shelf stays clear of the Dock and remembers your paste destination.

## Privacy and limitations

- History is local. There is no telemetry. Confidential/temporary clipboard markers
  are always excluded; likely-secret filtering is also enabled by default.
- Secret detection is best effort. Pause capture before copying sensitive content.
- History and managed attachments are encrypted with a stable local key. If the
  key is unavailable, capture pauses instead of writing new plaintext history.
- Archive exports are unencrypted: store and share them carefully.
- iCloud is optional whole-history backup in appropriately entitled builds, not live
  multi-device sync. This preview does not include iPhone/iPad or shared Pinboards.
- This is an early preview. A local-preview ZIP is not notarized and may be blocked
  by macOS. Do not disable Gatekeeper; use a Developer ID-signed, notarized release
  for ordinary distribution.

Settings > Data exports/imports archives containing history, Pinboards, and managed
attachments, and offers optional iCloud backup/restore. Export individual Pinboards
from their context menus. See [security notes](SECURITY.md) for storage and archive details.
