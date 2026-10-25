# Upgrading and recovery

Goldfish 0.2.0 uses `com.local.goldfish` as its default bundle/defaults identity, `Goldfish` as its Application Support folder, `com.local.goldfish.encryption` as its Keychain service, and `.goldfisharchive` for new exports. Encryption writes use `goldfish:v1:`. The cloud archive is `Documents/Goldfish/Goldfish.goldfisharchive` in the entitled container.

## Upgrade

Quit all older copies before installing. First launch copies the older application folder into a private staging directory, adopts the existing key under the new Keychain service, rewrites encrypted database fields and managed attachment paths, updates sidecar prefixes without changing encrypted bodies, and checks the database before publishing the new folder. Files use owner-only permissions. Preferences are copied only where Goldfish has no value already.

Older unused cache files can belong to retired keys. Their encrypted bodies are preserved and do not block migration of readable current clips. Migration does not recover a missing retired key.

The original folder and original Keychain item remain unchanged for recovery. A failed migration removes its staging folder and stops startup instead of capturing into a partial profile. A later launch can retry. An existing Goldfish data folder is never overwritten or automatically merged with the older folder. File references outside managed images, thumbnails, and attachments remain external references.

New exports and backups use Goldfish names. Import accepts both the new extension and the older portable archive extension. Within the same entitled iCloud container, the older cloud archive is copied to the new location only if no new backup exists; the original remains available. A different distribution container does not automatically gain access to backups in another container.

The new bundle identity may require granting Accessibility access again for automatic paste and reviewing Login Items in System Settings. Clipboard capture and copy do not require Accessibility access. Old privacy and login-item registrations are managed by macOS and are not silently deleted.

## If startup reports a migration error

1. Leave both application folders and Keychain entries intact. Do not clear history.
2. Quit older app copies and unlock the login Keychain, then retry.
3. Check free disk space and write access to your Application Support folder.
4. If a Goldfish folder already exists, preserve it separately before attempting any manual recovery. Do not combine databases or encryption keys by hand.
5. Ask for help using synthetic descriptions in [discussions](https://github.com/akkolli/goldfish/discussions), or use [private reporting](../SECURITY.md) for security-related details. Never upload databases or keys.

Only `GoldfishMigration` contains the old product identities needed to recognize saved data. Git history and archived source snapshots retain their original names. Development/test storage overrides use `GOLDFISH_STORAGE_DIR`; the explicit development-only keychain bypass is `GOLDFISH_DISABLE_KEYCHAIN`.

## Retained originals

The migration leaves an additional recoverable copy of clipboard history. Clearing history in Goldfish does not erase the old profile, old exports, cloud copies, system backups, or filesystem snapshots. Keep or remove recovery copies deliberately once you have verified your migrated history and attachments. Migration does not promise secure erasure from an SSD.
