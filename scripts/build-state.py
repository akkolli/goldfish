#!/usr/bin/env python3
"""Validate checkout freshness and record the inputs used to build Goldfish."""
import datetime
import functools
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def validate_name(info):
    for key in ('CFBundleDisplayName', 'CFBundleName', 'CFBundleExecutable'):
        if info.get(key) != 'Goldfish':
            raise ValueError(f'{key} must be Goldfish, found {info.get(key)!r}')


@functools.lru_cache()
def toolchain(developer_dir):
    def output(*args):
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    return dict(swift=output('xcrun', 'swift', '--version'), sdk=output('xcrun', '--sdk', 'macosx', '--show-sdk-path'),
                sdkVersion=output('xcrun', '--sdk', 'macosx', '--show-sdk-version'))


def snapshot(root, allow_dirty=False):
    root = root.resolve()
    main = git(root, 'rev-parse', '--verify', 'refs/heads/main')
    revision = git(root, 'rev-parse', 'HEAD')
    if subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', main, revision]).returncode:
        raise ValueError(f'Stale checkout: {root} does not include current main ({main[:12]})')
    for block in git(root, 'worktree', 'list', '--porcelain').split('\n\n'):
        lines = block.splitlines()
        if 'branch refs/heads/main' in lines:
            primary = Path(lines[0].removeprefix('worktree ')).resolve()
            if primary != root and git(primary, 'status', '--porcelain'):
                raise ValueError(f'Main has uncommitted changes in {primary}; build there first')
    dirty = bool(git(root, 'status', '--porcelain'))
    if dirty and not allow_dirty:
        raise ValueError('Commit the verified changes before building; use --allow-dirty for a development preview')
    info = plistlib.loads((root / 'Sources/Goldfish/resources/Info.plist').read_bytes())
    validate_name(info)
    package = (root / 'Package.swift').read_text()
    names = set(re.findall(r'name:\s*"([^"]+)"', package))
    if names != {'Goldfish', 'GoldfishTests'}:
        raise ValueError(f'Package and target names must be Goldfish / GoldfishTests, found {sorted(names)}')
    config = (root / 'Sources/Goldfish/config/AppConfig.swift').read_text()
    if 'static let appName = "Goldfish"' not in config:
        raise ValueError('AppConfig.appName must be Goldfish')
    paths = git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split('\0')
    # SwiftPM discovers files independently of Git. Include ignored compiler and
    # resource inputs too, and require an explicit preview for unpublished inputs.
    discovered = {str(path.relative_to(root)) for directory in ('Sources', 'Tests')
                  for path in (root / directory).rglob('*') if path.is_file()
                  and path.name != '.DS_Store' and '__pycache__' not in path.parts}
    dirty = dirty or bool(discovered - set(paths))
    if dirty and not allow_dirty:
        raise ValueError('Commit all compiler/resource inputs before building; use --allow-dirty for a development preview')
    paths = set(paths) | discovered
    inputs = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
              for name in sorted(paths) if name and (root / name).is_file()}
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    entitlements = os.environ.get('ENTITLEMENTS_FILE')
    environment = dict(architectures=os.environ.get('ARCHITECTURES', os.uname().machine),
                       entitlementsHash=hashlib.sha256(Path(entitlements).read_bytes()).hexdigest() if entitlements else None,
                       **toolchain(os.environ.get('DEVELOPER_DIR')))
    return dict(schemaVersion=2, appName='Goldfish', revision=revision, sourceHash=digest, buildEnvironment=environment,
                checkout=str(root), branch=git(root, 'rev-parse', '--abbrev-ref', 'HEAD'), dirty=dirty,
                bundleIdentifier=os.environ.get('APP_BUNDLE_IDENTIFIER', info['CFBundleIdentifier']))


def verify(root, recorded):
    if recorded.get('schemaVersion') != 2:
        raise ValueError('Build provenance uses an old format; rebuild with the current build script')
    current = snapshot(root, allow_dirty=recorded['dirty'])
    for key in ('revision', 'sourceHash', 'checkout', 'dirty', 'buildEnvironment', 'bundleIdentifier'):
        if current[key] != recorded[key]:
            raise ValueError(f'Build no longer matches current source ({key}); rebuild from this checkout')
    return current


def installable(root, app):
    path = app / 'Contents/Resources/BuildInfo.json'
    if not path.is_file():
        raise ValueError('App has no build provenance; rebuild with scripts/build-macos-app.sh')
    recorded = json.loads(path.read_text())
    if recorded['dirty'] or recorded['revision'] != git(root, 'rev-parse', 'refs/heads/main'):
        raise ValueError('Install requires a clean build of current main; commit, switch to main, and rebuild')
    verify(root, recorded)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    validate_name(info)
    if info['CFBundleIdentifier'] != recorded['bundleIdentifier']:
        raise ValueError('Bundle identity differs from its build provenance')
    return recorded


def main():
    root = Path(__file__).resolve().parent.parent
    mode, path, *options = sys.argv[1:]
    path = Path(path)
    if mode == 'capture':
        state = snapshot(root, allow_dirty='--allow-dirty' in options)
        state['builtAtUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        path.write_text(json.dumps(state, indent=2) + '\n')
    elif mode == 'verify':
        state = verify(root, json.loads(path.read_text()))
    elif mode == 'installable':
        state = installable(root, path)
    else:
        raise ValueError(f'Unknown build-state command: {mode}')
    print(f"Goldfish source: {state['revision'][:12]} ({state['branch']}, "
          f"{'development preview' if state['dirty'] else 'committed'}), {state['checkout']}")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'FAIL: {error}')
