#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

bash "$SCRIPT_DIR/require-app-stopped.sh"
for script in "$SCRIPT_DIR/"*.sh; do bash -n "$script"; done
python3 -m unittest discover -s Tests/BuildTools -p 'test_*.py'
python3 "$SCRIPT_DIR/check-docs.py"
python3 "$SCRIPT_DIR/project-metrics.py" --max-test-lines 999 --max-doc-lines 999
git diff --check
swift test -q
"$SCRIPT_DIR/build-macos-app.sh" --allow-dirty
codesign --verify --deep --strict --verbose=2 "$REPO_ROOT/build/Goldfish.app"
