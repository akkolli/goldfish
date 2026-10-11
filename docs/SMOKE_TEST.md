# Manual Smoke Test Checklist

Use this checklist before a release or after changes to the shelf, pasteboard, settings, permissions, storage, launch-at-login, or packaging behavior.

## Setup

1. Quit running copies before `./scripts/check.sh`; capture/paste tests use isolated clipboards. Set `GOLDFISH_TEST_SCREEN` to a display name to keep interface checks on that screen. Then open `build/Goldfish.app`.
2. With fresh preferences, confirm the compact welcome screen appears before the shelf. It shows a card-shelf preview, shortcut chooser, optional automatic-paste permission, privacy summary, and one Start button. Check light/dark appearance and bottom-button clearance. Advanced preferences belong in Settings, not setup.
3. Copy a unique marker while setup is open. Start using Goldfish and confirm that marker is not backfilled. Relaunch and confirm the welcome screen does not return. Reopening setup must preserve retention, secret filtering, login, and Dock preferences.
4. Confirm the menu-bar icon appears when `Show Goldfish in the menu bar` is enabled.
5. Click the menu-bar icon repeatedly: the shelf must alternate open/closed, including during its animation. Repeat with search focused and with a new-clip editor or filter menu open: a closing click must not restart the opening animation. Click outside the shelf to dismiss it; a new icon click must reopen immediately, even during the closing animation. Right-click and Control-click must still show the status menu. Repeat on another display when available.

## Capture And Preview Loading

1. Copy plain text, code, a URL, a color, an image, audio, video, rich text, a PDF, one Finder file, and multiple Finder files. Confirm each appears with the correct kind and grouped files remain one clip.
2. Confirm a new card appears immediately even when its preview is not cached. Keep searching and scrolling while the thumbnail loads, then confirm the card updates in place without changing selection or scroll position.
3. Confirm URL and video thumbnails appear when source data is available, and that a missing or failed thumbnail leaves a usable fallback card.
4. Enable `Search in image labels`, copy an image containing readable text, and confirm the OCR text is searchable after processing finishes.
5. Disable a content kind in Settings > Capture, copy that kind again, and confirm it is skipped. Re-enable it afterward.
6. Copy from an ignored source app and confirm the capture status reports that the item was skipped.
7. Choose Links, then copy ordinary text in another app. Confirm the filtered count shows a subset of total history and a new-copy notice appears. Choose Show new and confirm History / All types / Newest, with the new text selected. Repeat with a search and a named Pinboard, including while the shelf is closed. Captures must not replace pending Undo or other action feedback.

## Search and navigation

1. Open the shelf and verify Search clips stays visible when empty, focused, and unfocused. Command-F repeatedly focuses the same field.
2. Type a query, then Escape to clear it and Escape again to dismiss. Verify results update immediately.
3. Choose a named Pinboard, choose Text, then Most used. Confirm type and order apply within that board; changing one does not reset the others.
4. Search for a nonexistent phrase. All destinations/types must remain available. Use the inline reset and confirm scope and search clear.
5. Use Filter > Source app and Copied today, and inspect the inserted tokens. Also try `pinboard:"Client Work" type:image,pdf device:<Mac name>`.
6. Tab through search, native popups, filters, cards, and footer actions. Check visible focus, arrow-key popup operation, and VoiceOver names/values.

## Cards, Selection, And Actions

1. Confirm the default shelf opens vertically on the chosen screen edge. Cards use a single column with readable titles, type/time headers, source app icons, substantial content previews, and continuous corners. Check Compact, Standard, and Wide widths.
2. Hover cards: rows must stay still. Copied content is visible before selection. A short clip stays compact. Selecting, hovering, and changing keyboard focus must preserve every card’s frame. From search, Down enters the selected result without skipping it; Space previews.
3. Move focus with the keyboard while another card is hovered. Confirm selection and keyboard focus remain distinguishable.
4. Confirm card and category transitions feel continuous rather than snapping. Enable macOS System Settings > Accessibility > Display > Reduce Motion and confirm panel, search, category, and card transitions become immediate; restore the original system setting afterward.
5. Right-click representative text, link, image, file, and media cards. Confirm applicable commands appear in the context menu: paste/copy, plain-text variants, preview/open, edit/rename, pin/collect, image rotate/extract text, capture rules, show in Clipboard, and delete.
6. With a card focused, confirm `Return` pastes, `Shift + Return` uses plain text, `Command + C` copies, `Space` or `Command + Y` previews, `Command + O` opens applicable clips, `Command + E` edits text/code, and `Command + R` renames without changing the payload.
7. Press `Command + 1` through `Command + 9` and confirm the matching numbered cards are used; add `Shift` and confirm plain-text output.
8. Command-click non-adjacent cards and Shift-click a range. Confirm context-menu batch actions use the selected set and `Command + A` selects all visible cards.
9. Delete multiple selected clips, press `Command + Z`, and confirm the batch returns selected.
10. From a filtered result, choose Show in Clipboard or press `Command + G`; confirm search clears and the same clip stays selected in Clipboard.
11. Double-click a card and confirm paste or copy fallback occurs without creating a duplicate history item.
12. Confirm cards show actual copied text, optional custom titles, images, document previews, and readable link/media fallbacks. Missing source apps must not display `Unknown`.
13. On multiple displays and Spaces, confirm the shortcut opens on the pointer's active display/Space and the menu-bar icon opens on its display. Verify both left and right placement in Settings > General. Check the optional Horizontal shelf, then return to Vertical shelf.
14. Type `p` and confirm it searches instead of pinning. Command-P toggles pinning. Command-N or the pencil button creates a note without overwriting the system clipboard; inside a Pinboard the new note belongs to that board.
15. Test every shelf width and larger text with legacy and overlay scrollbars. Card corners and text must fit the actual clip width. Browse older clips and copy again: the clip under the viewport must remain stable, including when a different-height clip is inserted. Search changes must reveal their results at the top.
16. The trash button offers 1 day, 1 week, and All time cleanup. Pinboard deletion and the full history reset in Settings require confirmation with Cancel as the default; ordinary cleanup keeps pinned and collected clips.

## Hover, Scrollbars, And Filter Menus

1. Move between adjacent cards: the hovered card springs forward and neighboring cards recede slightly. Selection, hit targets, row positions, and scroll offset must remain stable. Scroll or browse with the keyboard to clear hover. With Reduce Motion, cards remain still.
2. Check overlay and Always Show Scroll Bars. The narrow rounded thumb must remain draggable and accessible, with no contrasting track or clipped card corners. Check narrow/wide shelves and light/dark appearances.
3. Use the destination and content-type icons, then open Filters. Check icons, counts, selected states, menu grouping, and complete titles. Choose a type inside a Pinboard and while searching: the surrounding scope must remain intact.
4. Use hardware arrow keys, type-ahead, Return, and Escape. An open menu must retain keyboard focus if its parent window briefly becomes key. Escape returns to the opening button. Clicking the same button closes its menu; clicking another filter switches menus. Clicking a card or scrolling outside closes the menu.
5. Choose different source apps and date ranges. Each replaces its previous choice while preserving free text and other filters. All apps clears only the source filter. Clear search and filters restores history.

## Horizontal Shelf

1. Switch General > Layout to Horizontal shelf. Check Compact, Standard, and Wide with both text sizes. Search, destinations, content types, and actions share one top row, with sort at the far right. The shelf spans the display with a 12 pt margin on each side and at the bottom, above the Dock; ultrawide displays must not hit a fixed width cap.
2. Check small/scaled displays, a side Dock, and a second screen with a nonzero origin. Cards and toolbar controls must fit; card footers and hover lifts must clear both overlay and legacy scrollbars. Horizontal edge fades should reveal the shelf material without opaque strips.
3. Browse with the mouse wheel, trackpad, and scrollbar. Use Left/Right, Home/End, Page Up/Down, Shift-selection, and Command-A. Move to the last clip in a long history and back; offscreen cards must render immediately without shifting the viewport on new copies.
4. Combine a Pinboard, content type, search, and sort. On narrow displays, scroll both icon groups to reach their last controls. Select the last Pinboard in an overflowing destination lane; it must remain fully visible when Reset appears. Test no results, Clear Search, and Show new. The new-copy action must stay in the top row without pushing card footers under the scrollbar.
5. Open, toggle, and switch between New Clip, New Pinboard, filters, and Clear History. Only one auxiliary dialog should remain visible. Save and edit a test clip; check copy/paste, pinning, context-menu actions, delete, and undo. Clear History actions should be exercised only in an isolated test profile.
6. Open a preview and close it; focus should return to the selected card. Close the shelf while a dialog or preview is open and reopen it. Confirm no abandoned windows remain. Switch between layouts while filtered and verify that scope and selection survive.

## Sound Effects

1. In Settings > General > Sound effects, preview both camera-click cues while the switches are off. Previewing must not enable sounds, and clicking a preview again must replay it immediately. Enable Copy sound and Paste sound independently, adjust volume, and verify these choices survive relaunch.
2. Copy from another app, copy a clip from the shelf, and paste through Goldfish. Each action should have one short cue; the paste cue starts when the paste is sent. Plain-text and multiple-clip transfers use the same cues. A copy-only fallback uses the copy cue; failed writes and cancelled paste delivery are silent.
3. Copy rapidly: cues must not overlap, build up, or continue afterward. A pause restores their normal softness. Paused capture, excluded content, unchanged clipboard polls, and Goldfish's own pasteboard writes must not cause extra capture cues. Ordinary paste shortcuts outside Goldfish are silent.
4. Set sound volume to zero and disable each switch. Confirm silence, then check that system mute and output volume still govern playback. Check speaker and headphone comfort at the default 30% setting. On Bluetooth output, copies about 0.2 seconds apart and copy/paste pairs must not become silent while the previous sound drains its device buffers. Switch output devices and confirm the next cue still plays.

## Pinboards

1. Press `Shift + Command + N` or choose New Pinboard from the destination menu to create `Client Work`; confirm its name remains available when empty.
2. Assign selected cards through More > Add to Pinboard. Confirm assignment and configured color survive relaunch and history pruning. Test dragging clips into other apps; check drag-to-Pinboard targets in the optional horizontal layout.
3. Use the destination menu to edit the selected Pinboard’s name/color, export it, and delete it. Import the archive into a fresh profile and confirm clips plus empty Pinboard metadata are restored.
4. With no Pinboards, right-click a clip and confirm New Pinboard appears directly. After creating one, confirm only user-created Pinboards appear in Add to Pinboard.

## Copy And Paste

1. Copy/paste text, URL, image, audio, video, PDF, rich text, and file clips into suitable apps. Confirm original pasteboard representations are preserved.
2. Paste a multi-file clip into Finder and confirm all file references are present.
3. Use plain-text paste on URL and rich-text clips and confirm formatting and non-text representations are omitted.
4. Without Accessibility permission, confirm paste falls back to copying and Settings > Privacy reports the permission requirement.
5. With Accessibility permission, confirm paste returns focus to the previous app and inserts the selected clip.
6. Preview text, a link, an image, and a PDF. The shelf remains visible; close or Escape returns to the same selected card. Click another app: both shelf and preview dismiss. Open Settings: the shelf dismisses. Reopen from the menu bar and verify the destination app remains correct.
7. Check both shelf sides with bottom/side/hidden Dock, multiple monitors and fullscreen Spaces. Keep a 12 pt visible-screen margin; a short entrance must not sweep across the display.
6. If focus moves to another app or the clipboard changes before a queued paste fires, confirm Goldfish cancels that paste rather than sending it to the wrong destination.

## Settings

1. With the Goldfish pane open, open Settings with `Command + ,` and confirm a resizable window with six sidebar sections: `General`, `Shortcuts`, `Capture`, `Privacy`, `Performance`, and `Data`. Close the pane, switch to another app, and confirm `Command + ,` opens that app's settings instead of Goldfish.
2. Resize to the practical minimum. Visit every tab and confirm content stays anchored to the top-left, scrolls vertically when needed, and has no horizontal clipping, zero-sized controls, or duplicate selector labels.
3. In General, change shelf side, Keep History, history length, default sort, launch-at-login, and menu-bar/Dock presence. Relaunch and confirm persistence.
4. In Shortcuts, click Change and record a combination. Test invalid/conflicting combinations, Escape cancellation, switching tabs, and closing Settings mid-recording. Verify the correct global shortcut works afterward.
5. In Capture, pause/resume capture, toggle likely-secret exclusion and image-label search, edit ignored apps, and toggle allowed content types. Confirm at least one content type must remain enabled and status feedback stays inside this tab.
6. In Privacy, test clear-on-quit, screen-capture hiding, Accessibility settings, permission refresh, and paste-status feedback.
7. In Performance, change the polling profile and thumbnail-cache cap. Confirm capture continues at the selected cadence, UI input remains responsive while polling, and the values persist.
8. In Data, export/import an archive, exercise available iCloud backup/restore controls, open the history folder, and confirm destructive clear actions require confirmation and show success or error feedback in the Data page. Enabling backup must not restore remote history automatically.
9. Change one control and confirm unrelated tabs do not jump, reset, or flash; long status messages should wrap instead of widening the window.

## Storage And Privacy

1. Open the data folder and confirm `history.sqlite`, `images/`, `thumbnails/`, and `attachments/` appear as applicable.
2. Copy unique text and managed attachment data; confirm `strings` does not expose the test content from the SQLite database or encrypted sidecars.
3. Treat exported and iCloud `.clipboredarchive` files as sensitive because they are portable and not encrypted by Goldfish. Confirm files over the 128 MB archive limit are rejected cleanly.
4. Open or reveal encrypted media, quit Goldfish, and confirm temporary preview files under `/tmp/ClipBored/Previews` are removed.
5. Use the explicit full-data reset in Settings > Data and confirm saved rows, full images, managed attachments, temporary previews, and any legacy fallback encryption key are removed when present. Ordinary shelf cleanup preserves pins and Pinboards. Clear the thumbnail cache separately and confirm history and full copied images remain usable.
6. Enable `Clear history on quit`, relaunch, and confirm history and managed cache/attachment files were removed.
7. In an isolated test profile, simulate an unavailable encryption key: new captures and archive import must fail closed, never write plaintext, and leave old records untouched. Import must also refuse to proceed when history contains unreadable encrypted records.
8. Copy content with concealed/transient/generated pasteboard markers. Confirm it is excluded even when best-effort secret filtering is disabled.

## Launch And Lifecycle

1. Enable and disable Launch at Login and verify the next login behavior each time.
2. Right-click or Control-click the menu-bar icon and confirm the menu includes capture state/count, Open Goldfish, Settings, pause/resume options, and Quit.
3. Test a timed pause, manual pause, and resume; confirm copies made while paused are not captured later on resume. A new copy after resume should capture normally.
4. Quit from the menu-bar menu and confirm no `Goldfish` process remains.

## Design and accessibility release checks

- Close first-run welcome and verify setup stays incomplete and capture stays off. Menu bar, Dock reopen, open shortcut, and New Clip should return to setup. Only Start enables capture.
- Test Copy fallback with no target or Accessibility permission. Confirm the shelf stays open and explains Command-V. With a valid target and permission, check the destination label and actual paste.
- Delete multiple clips and undo with Command-Z. Trigger an unavailable attachment/preview and confirm its accessibility announcement. Capture updates must not erase action feedback.
- Pause/resume from Settings or the status menu and verify actual capture state. A blocked encryption key must report attention needed rather than normal capture.
- Create/edit a clip in the attached sheet. Empty Save is disabled. Command-Return saves, Escape cancels, and the shelf remains open. Test a failed save and recovery; drafts must survive.
- Check all widths, larger text, both appearances, legacy/overlay scrollbars, and 100%/200% displays. Inspect title/excerpt truncation, footer wrapping, and long Pinboard/app names.
- Manually run find/preview/copy/pin/delete/undo with VoiceOver and Voice Control. Cards should be single navigation stops with custom actions; clipped preview children must not appear as extra stops.
- Validate Increase Contrast, Reduce Transparency, and Reduce Motion, restoring the tester's original settings. Check contrast and macOS 13–15 fallbacks. Automated layout/AX checks are not accessibility certification.
