# Release Guide

This guide covers the local release build, optional Developer ID signing, and optional notarization flow.

## Local Validation

Run:

```bash
./scripts/check.sh
```

This runs the unit test suite, builds `build/Goldfish.app`, applies an ad-hoc hardened-runtime signature, enforces a 2 MiB executable budget per architecture and a bundle budget of that amount plus 1 MiB for the modern icon assets (3 MiB for one architecture, 5 MiB for universal builds), and verifies the app signature.

The linker records the SDK actually selected by Xcode and the deployment minimum from Info.plist. On Xcode 26+, the build also compiles the layered app icon and its appearance assets; older SDKs retain the full-resolution `.icns` fallback. Inspect `xcrun vtool -show-build build/Goldfish.app/Contents/MacOS/Goldfish` when checking SDK or deployment-target changes.

## Local Archive

Run:

```bash
./scripts/release-macos-app.sh
```

Without signing credentials, this creates:

```text
build/Goldfish.app
build/Goldfish-local-preview.zip
```

The app remains ad-hoc signed and is suitable for local validation only. Release builds default to universal Apple Silicon/Intel binaries. Do not describe this archive as a notarized public release.

## Developer ID Signing

Set a Developer ID Application identity:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)"
./scripts/release-macos-app.sh
```

The script rebuilds the app, re-signs it with hardened runtime and timestamping, and verifies the signature. Without notarization credentials, the archive is named `build/Goldfish-signed-unnotarized.zip`.

## Bundle Identity And iCloud Backup Entitlements

The default local and release scripts keep the development bundle identifier `com.local.goldfish` and do not add iCloud entitlements. `Back up history to iCloud` reports unavailable in those builds.

For a distribution build, supply the release identifier and entitlement file explicitly:

```bash
export APP_BUNDLE_IDENTIFIER="com.example.Goldfish"
export ENTITLEMENTS_FILE="$PWD/Config/Goldfish.entitlements"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)"
./scripts/release-macos-app.sh
```

The scripts write `APP_BUNDLE_IDENTIFIER` into the packaged Info.plist and apply `ENTITLEMENTS_FILE` during both the ad-hoc build signature and the Developer ID signature. Verify that the entitlement grants the matching ubiquity container, then repeat the signature, backup/restore smoke, and notarization checks.

## Notarization

Preferred: configure a notarytool keychain profile once:

```bash
xcrun notarytool store-credentials "goldfish-notary" \
  --apple-id "developer@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then run:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)"
export NOTARYTOOL_PROFILE="goldfish-notary"
./scripts/release-macos-app.sh
```

Alternative environment-only notarization:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)"
export APPLE_ID="developer@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_SPECIFIC_PASSWORD="app-specific-password"
./scripts/release-macos-app.sh
```

When notarization succeeds, the script staples the ticket to `build/Goldfish.app`, validates the staple, and recreates `build/Goldfish.zip`.

Use `./scripts/release-macos-app.sh --require-notarization` for the final public build.
It fails early when credentials are missing and requires Gatekeeper assessment to pass.
The app includes its GPL license and a short getting-started guide, but no clipboard
history, demo archive, local preferences, or encryption keys. Include the matching
GPL-licensed source when distributing binaries. Do not publish a source snapshot
without reviewing it for project-specific private files first.

## Final Manual Checks

Before publishing, run the checklist in [SMOKE_TEST.md](SMOKE_TEST.md), then confirm:

```bash
codesign --verify --deep --strict --verbose=2 build/Goldfish.app
xcrun stapler validate build/Goldfish.app
spctl --assess --type execute --verbose=4 build/Goldfish.app
```

## Source identity and local installation

Release and default builds require committed sources that include current `main`. The check command permits an explicitly marked development preview; the installer rejects it. Goldfish bundles include `Contents/Resources/BuildInfo.json` with the source commit, hash, checkout and build time. A source change during packaging fails the build.

After committing and quitting Goldfish, run `./scripts/install-macos-app.sh`. It rebuilds current `main`, validates the app name, source provenance and signature, preserves the previous app, installs to `/Applications/Goldfish.app`, and launches the installed copy. An optional absolute destination ending in `Goldfish.app` supports a user Applications folder.

## Release identity

Before a release, increment `CFBundleShortVersionString` and `CFBundleVersion` in `Sources/Goldfish/resources/Info.plist`. Run `scripts/check.sh`, commit and publish clean main, then tag that verified commit (for example `v0.2.0`). Build through the release script from that checkout and retain its `BuildInfo.json` with the binary and matching source. Settings displays the version and short source revision; dirty previews are labeled. Public distribution still requires the documented signing, notarization, and manual smoke checks.

Provenance includes every compiler/resource input even when ignored by Git, toolchain and SDK identity, architecture selection, and external entitlement contents. Unpublished target inputs require an explicit development preview. Process inspection failure prevents checks and installation.
