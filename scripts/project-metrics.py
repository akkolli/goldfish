#!/usr/bin/env python3
"""Count every maintained text file, including comments and blank lines."""
import argparse
import json
import os
from pathlib import Path
import subprocess

GENERATED = {'.git', '.build', 'build', '.swiftpm', 'DerivedData', '__pycache__', '.DS_Store'}


def files_under(root):
    for directory, names, files in os.walk(root):
        names[:] = [name for name in names if name not in GENERATED]
        for name in files:
            path = Path(directory) / name
            if name not in GENERATED and not path.is_symlink():
                yield path


def size(root):
    return sum(path.stat().st_size for path in files_under(root))


def text_metrics(files):
    lines = []
    text_files = 0
    text_bytes = binary_bytes = 0
    for path in files:
        data = path.read_bytes()
        try:
            if b'\0' in data:
                raise UnicodeError('binary file')
            decoded = data.decode('utf-8')
        except UnicodeError:
            binary_bytes += len(data)
            continue
        text_files += 1
        text_bytes += len(data)
        lines.extend(decoded.splitlines())
    return dict(files=text_files, lines=len(lines), nonblank_lines=sum(bool(line.strip()) for line in lines),
                bytes=text_bytes, binary_bytes=binary_bytes)


def measure(root):
    # Git excludes generated/local output. Also count ignored source/resource inputs:
    # SwiftPM consumes those even when Git does not, so ignoring code cannot hide it.
    names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
    paths = {root / name for name in names if name}
    for directory in ('Sources', 'Tests', 'scripts', 'docs'):
        paths.update(files_under(root / directory))
    files = sorted(path for path in paths if path.is_file() and not path.is_symlink())
    groups = {name: text_metrics(path for path in files if path.is_relative_to(root / name))
              for name in ('Sources', 'Tests', 'scripts', 'docs')}
    groups['configuration_and_root'] = text_metrics(path for path in files
        if not any(path.is_relative_to(root / name) for name in groups))
    executable = root / 'build/Goldfish.app/Contents/MacOS/Goldfish'
    return dict(maintained_total=text_metrics(files), groups=groups,
                app_swift=text_metrics(path for path in files if path.is_relative_to(root / 'Sources') and path.suffix == '.swift'),
                test_swift=text_metrics(path for path in files if path.is_relative_to(root / 'Tests') and path.suffix == '.swift'),
                app_bundle_bytes=size(root / 'build/Goldfish.app'),
                executable_bytes=executable.stat().st_size if executable.exists() else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--max-lines', type=int, help='Fail when the maintained total exceeds this budget')
    args = parser.parse_args()
    report = measure(args.root.resolve())
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for name, group in [('TOTAL maintained text', report['maintained_total']), *report['groups'].items()]:
            print(f"{name}: {group['lines']:,} lines ({group['nonblank_lines']:,} nonblank), {group['files']} text files")
        total = report['maintained_total']
        print(f"Text: {total['bytes']:,} bytes; binary assets: {total['binary_bytes']:,} bytes")
        print(f"Built app: {report['app_bundle_bytes']:,} bytes; executable: {report['executable_bytes']:,} bytes")
        print('Counts include documentation, configuration, text assets, comments and blanks. Generated output is excluded.')
    if args.max_lines is not None and report['maintained_total']['lines'] > args.max_lines:
        parser.exit(1, f"Maintained text exceeds the {args.max_lines:,}-line budget.\n")


if __name__ == '__main__':
    main()
