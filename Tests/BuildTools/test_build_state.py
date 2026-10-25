import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_state', Path(__file__).resolve().parents[2] / 'scripts/build-state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class BuildStateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.info = self.root / 'Sources/Goldfish/resources/Info.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps(dict(CFBundleName='Goldfish', CFBundleDisplayName='Goldfish',
                                                 CFBundleExecutable='Goldfish', CFBundleIdentifier='com.local.goldfish')))
        config = self.root / 'Sources/Goldfish/config/AppConfig.swift'
        config.parent.mkdir()
        config.write_text('static let appName = "Goldfish"')
        (self.root / 'Package.swift').write_text('name: "Goldfish", name: "GoldfishTests"')
        self.commit()

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True)

    def commit(self):
        self.git('add', '-A')
        self.git('-c', 'user.name=Build Test', '-c', 'user.email=build@example.invalid', 'commit', '-qm', 'fixture')

    def worktree(self):
        path = Path(self.directory.name) / 'worktree'
        self.git('worktree', 'add', '-q', '--detach', str(path), 'HEAD')
        return path

    def test_committed_snapshot_and_source_changes(self):
        recorded = state.snapshot(self.root)
        self.assertFalse(recorded['dirty'])
        state.verify(self.root, recorded)
        (self.root / 'new.swift').write_text('new code')
        with self.assertRaisesRegex(ValueError, 'Commit'): state.snapshot(self.root)
        preview = state.snapshot(self.root, allow_dirty=True)
        self.assertTrue(preview['dirty'])
        (self.root / 'new.swift').write_text('changed code')
        with self.assertRaisesRegex(ValueError, 'sourceHash'): state.verify(self.root, preview)

    def test_stale_worktree_and_uncommitted_main_are_rejected(self):
        other = self.worktree()
        (self.root / 'new.swift').write_text('new code')
        with self.assertRaisesRegex(ValueError, 'Main has uncommitted'): state.snapshot(other, allow_dirty=True)
        self.commit()
        with self.assertRaisesRegex(ValueError, 'Stale checkout'): state.snapshot(other)

    def test_old_branding_and_package_names_are_rejected(self):
        for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable'):
            info = plistlib.loads(self.info.read_bytes())
            info[key] = 'OtherApp'
            with self.assertRaisesRegex(ValueError, key): state.validate_name(info)
        (self.root / 'Package.swift').write_text('name: "OtherApp"')
        with self.assertRaisesRegex(ValueError, 'Package'): state.snapshot(self.root, allow_dirty=True)

    def test_install_requires_provenance_clean_main_and_matching_source(self):
        app = Path(self.directory.name) / 'Goldfish.app'
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(self.info.read_bytes())
        with self.assertRaisesRegex(ValueError, 'no build provenance'): state.installable(self.root, app)
        recorded = state.snapshot(self.root)
        manifest = resources / 'BuildInfo.json'
        manifest.write_text(json.dumps(recorded))
        state.installable(self.root, app)
        recorded['dirty'] = True
        manifest.write_text(json.dumps(recorded))
        with self.assertRaisesRegex(ValueError, 'clean build'): state.installable(self.root, app)
        recorded['dirty'] = False
        recorded['sourceHash'] = 'wrong'
        manifest.write_text(json.dumps(recorded))
        with self.assertRaisesRegex(ValueError, 'sourceHash'): state.installable(self.root, app)

    def test_build_from_another_checkout_is_rejected(self):
        recorded = state.snapshot(self.root)
        with self.assertRaisesRegex(ValueError, 'checkout'): state.verify(self.worktree(), recorded)

    def test_ignored_compiler_inputs_and_build_environment_are_verified(self):
        (self.root / '.gitignore').write_text('Sources/Goldfish/Local.swift\n')
        self.commit()
        recorded = state.snapshot(self.root)
        (self.root / 'Sources/Goldfish/Local.swift').write_text('compiled despite gitignore')
        with self.assertRaisesRegex(ValueError, 'Commit'): state.snapshot(self.root)
        preview = state.snapshot(self.root, allow_dirty=True)
        self.assertNotEqual(preview['sourceHash'], recorded['sourceHash'])
        (self.root / 'Sources/Goldfish/Local.swift').write_text('changed ignored source')
        with self.assertRaisesRegex(ValueError, 'sourceHash'): state.verify(self.root, preview)
        (self.root / 'Sources/Goldfish/Local.swift').unlink()
        with patch.dict(os.environ, ARCHITECTURES='x86_64' if recorded['buildEnvironment']['architectures'] != 'x86_64' else 'arm64'):
            with self.assertRaisesRegex(ValueError, 'buildEnvironment'): state.verify(self.root, recorded)
        entitlement = Path(self.directory.name) / 'external.plist'
        entitlement.write_text('first')
        with patch.dict(os.environ, ENTITLEMENTS_FILE=str(entitlement)):
            recorded = state.snapshot(self.root)
            entitlement.write_text('changed')
            with self.assertRaisesRegex(ValueError, 'buildEnvironment'): state.verify(self.root, recorded)

    def test_process_guard_rejects_running_app_and_inspection_errors(self):
        directory = Path(self.directory.name) / 'bin'
        directory.mkdir()
        pgrep = directory / 'pgrep'
        script = Path(__file__).resolve().parents[2] / 'scripts/require-app-stopped.sh'
        for status in (0, 1, 2, 3):
            with self.subTest(status=status):
                pgrep.write_text(f'#!/bin/sh\nexit {status}\n')
                pgrep.chmod(0o755)
                result = subprocess.run(['/bin/bash', str(script)], capture_output=True,
                                        env={**os.environ, 'PATH': str(directory)})
                self.assertEqual(result.returncode == 0, status == 1)
