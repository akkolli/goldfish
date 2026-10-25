# Security policy

## Supported versions

The latest `main` and the newest published preview are supported development versions. Older archived branches and tags do not receive security backports. Goldfish is not yet distributed as a notarized public binary.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/akkolli/goldfish/security/advisories/new). Please do not post exploit details, real clipboard contents, databases, encryption keys, or private exports in public issues.

Include the affected commit/version, macOS version, reproduction steps using synthetic data, expected behavior, impact, and whether persistence, permissions, clipboard transfer, archives, or previews are involved. There is no promised response SLA or paid bounty program. Please coordinate public disclosure with the maintainer while a report is investigated.

For ordinary bugs, use the [issue forms](https://github.com/akkolli/goldfish/issues/new/choose).

## Security model

Clipboard capture, search, and local image OCR run on the Mac. Goldfish has no telemetry or account requirement. Explicit web previews contact the selected website; optional iCloud whole-history backup uses Apple's ubiquity APIs and requires entitlements. Both are distinct from clipboard polling.

Sensitive SQLite text fields and managed attachments are encrypted with a Keychain-held key. Older installations may have an existing owner-only fallback key; the app can read it during upgrade. It does not create a competing fallback key after an indeterminate Keychain write. Metadata and live decrypted previews have separate limitations.

Portable exports and iCloud backup archives are not encrypted by Goldfish. Store them as sensitive data. Migration keeps original files for recovery; clearing new history does not erase historical backups or filesystem snapshots. Review [the full security model](docs/SECURITY.md) for filesystem, preview, filtering, and permission limits.
