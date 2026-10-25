# Changelog

Notable user-visible changes are recorded here. Unreleased changes are on `main`; release tags identify exact source snapshots.

## 0.2.0 — Unreleased

### Changed

- Goldfish now uses its own storage directory, bundle/defaults identifier, Keychain service, encryption marker, pasteboard type, archive extension, and cloud-backup name.
- Automatic upgrade copies older history and attachments, rewrites managed paths and encryption prefixes, and imports preferences without overwriting new choices. Original files remain untouched.
- New exports use `.goldfisharchive`; old portable archives remain importable.
- The GitHub repository is now `akkolli/goldfish`, with documented contribution, conduct, security, and recovery paths.

### Fixed

- Clicking the menu-bar icon's right edge closes the shelf instead of triggering a close/reopen cycle.
- Card hover shadows follow the rounded card outline.
- The security policy now describes optional web previews, iCloud backup, and legacy keys accurately.

### Development

- Migration tests cover encryption, managed attachments, preferences, cloud backup, retries, wrong/missing keys, corrupt databases, and symbolic links.
- CI pins its external action, has bounded runtime and concurrency, and checks both current native behavior and release packaging.

## Earlier history

The `v0.1.1` tag and archived refactor history are preserved. Consult Git history for older implementation details; historical design screenshots are reference material, not current release evidence.
