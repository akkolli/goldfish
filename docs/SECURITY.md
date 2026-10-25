# Security Notes

Goldfish is designed as a local-first macOS utility. Its default privacy promise is that clipboard data stays on the machine unless iCloud Backup is explicitly enabled.

## Current Protections

- No telemetry. Network access is limited to explicit link previews and Apple's iCloud ubiquity container when backup is enabled.
- No shell/process execution.
- No Apple Events scripting.
- Hardened runtime is applied by the local build script, and the release script supports Developer ID signing plus notarization when credentials are configured.
- Clipboard persistence uses prepared SQLite statements and bound values.
- Textual SQLite fields, including optional local image OCR text, are encrypted with AES-GCM using a Keychain-held key when Keychain access is available.
- App-managed image cache files, audio clips, video clips, rich text sidecars, and PDF attachments are encrypted with the same encryption service.
- Keychain operations use a short noninteractive timeout. A duplicate-item response selects the existing stored key, and an indeterminate write never selects a newly generated competing key. Legacy owner-only fallback keys are still reused when present.
- If no stable encryption key is available, production capture and new saves stop with a visible status message. Managed attachment writes fail closed too. Explicit test/development encryption bypasses remain available for isolated fixtures. Full history clears remove a legacy app-local fallback key when present and reset cached key state after the database clear succeeds.
- Confidential, transient, and auto-generated pasteboard markers are excluded before reading their content, independently of heuristic secret filtering. The compatibility identifiers are documented at https://nspasteboard.org/.
- Import refuses to replace history while any records are unreadable. A delayed automatic paste checks both the destination app and the clipboard generation before posting the shortcut.
- App-owned storage directories are restricted to the current user, and saved history/cache files are written with owner-only permissions where the filesystem supports POSIX modes.
- Archive exports are written with owner-only permissions where supported and are limited to 128 MB. Managed clipboard payload capture is limited to 64 MB per item.
- iCloud Backup is off by default and uses the app-private ubiquity container only when entitlement access is available. Enabling it never implicitly restores a remote archive.
- Fresh profiles do not begin clipboard polling until onboarding is completed with Start, and likely-secret exclusion defaults on.
- Goldfish marks its own pasteboard writes so copy/paste actions from history are not re-captured as new clipboard events.
- The clipboard panel can be configured to opt out of screenshots, screen sharing, and screen recordings.
- Sensitive-content exclusion can skip common high-risk values:
  - private key blocks
  - bearer tokens
  - GitHub tokens
  - Slack tokens
  - AWS access key IDs
  - Stripe keys
  - OpenAI-style API keys
  - Google API keys
  - JSON Web Tokens
  - Luhn-valid credit-card-like values
  - OTP-like values from known authenticator/password-manager sources
  - long high-entropy token-like strings
  - obvious password/secret keywords and common secret assignment forms
- Default ignored apps include common password managers and authenticators.

## Known Limitations

- SQLite item metadata such as identifiers, kinds, timestamps, pin state, and use counts is not encrypted.
- A legacy app-local fallback key does not protect against a process or user account that can read the full Goldfish Application Support directory before history is cleared.
- Thumbnailing, opening, or revealing encrypted images, audio clips, video clips, or PDFs creates temporary decrypted preview files so macOS can hand them to system media APIs or other apps. Goldfish clears stale preview files on launch, cache/history clear, and quit.
- Existing plaintext SQLite rows and legacy sidecar files are migrated when encryption becomes available, but system snapshots, backups, live temporary previews, or filesystem remnants may retain older plaintext copies.
- Portable `.goldfisharchive` files and iCloud backup archives are not encrypted by Goldfish. They include recoverable clipboard metadata and app-managed attachment bytes so they can be imported on another Mac; store and transmit them like sensitive backups.
- iCloud Backup relies on the user's private iCloud account and Apple's ubiquity container transport/storage. It is one last-writer whole-history archive, not live multi-device sync. Goldfish does not add end-to-end archive encryption, tombstones, conflict resolution, or shared Pinboard access control.
- The local development build is ad-hoc signed; use `scripts/release-macos-app.sh` with Developer ID credentials for notarized distribution builds.
- Accessibility permission is required for automatic paste simulation.
- Screen-sharing privacy applies to Goldfish's panel window, not to other apps, system clipboard state, or filesystem history.
- Sensitive-content detection is heuristic and can miss novel formats or produce false positives.
- macOS pasteboard changes do not include a reliable originating-app identity. The ignored-app list is therefore a frontmost-app heuristic and can miss a copy if focus changes before Goldfish polls it.
- Automatic local image OCR is opt-in through `Search in image labels`; users can also run local OCR explicitly from an image card. Recognized text stays local but can still contain sensitive clipboard-derived content.
- User-triggered link preview loads the selected HTTP(S) URL in a non-persistent WebKit view. The destination site can still receive the request and normal browser-visible metadata for that preview load.
- Local filesystem access by another process or user account with sufficient permissions can expose metadata, fallback keys, and live temporary decrypted previews.

## Release Hardening Checklist

- Run `swift test -q`.
- Run `./scripts/build-macos-app.sh` or `./scripts/release-macos-app.sh`.
- Verify `codesign --verify --deep --strict --verbose=2 build/Goldfish.app`.
- Verify hardened runtime appears in `codesign -d --verbose=4 build/Goldfish.app`.
- For distribution, verify `xcrun stapler validate build/Goldfish.app` and `spctl --assess --type execute --verbose=4 build/Goldfish.app`.
- Confirm no new `URLSession`, process execution, Apple Events, or telemetry APIs were introduced; keep WebKit use limited to explicit link preview and keep backup limited to app-private iCloud ubiquity APIs.
- Review any new persistence paths for unencrypted sensitive data.
