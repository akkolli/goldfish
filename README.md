# Goldfish

[![Checks](https://github.com/akkolli/goldfish/actions/workflows/check.yml/badge.svg)](https://github.com/akkolli/goldfish/actions/workflows/check.yml)
[![License: GPL-2.0-only](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](LICENSE)

A native macOS clipboard manager. Keep the things you copy, find them quickly, and organize reusable clips into Pinboards.

- Search text, links, code, images, rich text, files, PDFs, audio, video, and colors.
- Choose a vertical shelf or horizontal cards, with keyboard navigation and light/dark appearances.
- Pin clips, create Pinboards, edit text, preview content, and undo deletion.
- Copy with a click or Return. Automatic paste is optional and requires Accessibility permission.
- Encrypt local history and managed attachments; exclude likely secrets and ignored apps.
- Export portable archives. Optional iCloud backup requires an entitled build.

## Project status

Goldfish is under active development. Source builds are available today; a Developer ID signed, notarized binary distribution is not yet configured. Build it yourself using the steps below. Do not treat an ad-hoc development archive as a notarized release.

Runs on macOS 13 or newer, on Apple Silicon and Intel. Building requires Xcode 16+ with the macOS 15+ SDK and Python 3.9+. There are no third-party runtime or Swift package dependencies.

## Build and install

```bash
git clone https://github.com/akkolli/goldfish.git
cd goldfish
./scripts/check.sh
./scripts/install-macos-app.sh
```

Quit any running Goldfish before checks or installation. The installer builds clean current `main`, verifies its source and signature, preserves the previous app, and opens `/Applications/Goldfish.app`. To install in your home folder, create `~/Applications` and pass `"$HOME/Applications/Goldfish.app"` to the installer.

On first launch, choose your capture settings and select **Start**. Open the fish menu-bar icon or press **Option–Command–V**. Use the search field to find a clip; click it or press Return to copy it. Accessibility access is only needed for automatic paste. See the [user guide](docs/QUICK_START.md).

Existing installations migrate history, attachments, preferences, and encryption keys to Goldfish identities. Original files remain available for recovery. Read [upgrading and recovery](docs/MIGRATION.md) before upgrading an older installation.

## Privacy

Capture and search run locally. Goldfish has no telemetry or account requirement. Local history and managed attachments are encrypted with a Keychain-held key; some metadata remains visible. Sensitive-content filtering is a heuristic and cannot guarantee that every secret is excluded.

Portable `.goldfisharchive` exports and iCloud backups are **not encrypted by Goldfish**. A web preview contacts the selected website only when you open it. iCloud backup is disabled by default and needs appropriate signing entitlements. See the [security model](docs/SECURITY.md) and [private vulnerability reporting](SECURITY.md).

## Contribute and get help

Use [issues](https://github.com/akkolli/goldfish/issues/new/choose) for reproducible bugs and focused feature requests, and [discussions](https://github.com/akkolli/goldfish/discussions) for questions and design proposals. Use synthetic clipboard examples; never upload your history database, encryption keys, private exports, or secrets.

Read [contributing](CONTRIBUTING.md), the [code of conduct](CODE_OF_CONDUCT.md), and the [roadmap](docs/ROADMAP.md). Small, focused pull requests with relevant verification are welcome. No contributor license agreement is required; contributions use the project's GPL-2.0-only license.

For development previews:

```bash
./scripts/build-macos-app.sh --allow-dirty
open build/Goldfish.app
```

Previews are explicitly marked and cannot pass the guarded installer. `scripts/check.sh` runs Swift and build-tool tests, documentation checks, shell syntax, whitespace, release packaging, signature verification, and binary size gates. It reports repository size without restricting regression coverage to an arbitrary line count.

## Documentation and license

[Documentation index](docs/README.md) · [Architecture](docs/ARCHITECTURE.md) · [Release guide](docs/RELEASE.md) · [Changelog](CHANGELOG.md)

Licensed under **GPL-2.0-only**. See [LICENSE](LICENSE). Redistributed binaries must include the license and provide the corresponding source under its terms. Historical design references are labeled as such and do not depict every current interaction.
