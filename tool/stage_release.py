#!/usr/bin/env python3
"""Build a minimal, inspectable pub.dev dry-run candidate. Never publishes."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_FILES = ('.pubignore', 'pubspec.yaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE')
SOURCE_TREES = ('lib', 'android', 'ios', 'example/lib', 'examples/push_adapters/lib')
# Keep contributor guides and visual comparison fixtures in the checkout.
PUBLIC_GUIDES = ('docs/guide.md', 'docs/ios-swift-package-manager.md',
                 'docs/presentation-lifecycle.md', 'docs/setup-diagnostics.md')
EXTRA_FILES = ('assets/fonts/Inter.ttf', 'assets/fonts/Inter-Italic.ttf', 'assets/fonts/OFL.txt', 'example/README.md', 'example/pubspec.yaml', 'examples/push_adapters/README.md', 'examples/push_adapters/pubspec.yaml', 'examples/push_adapters/ios/ChatAPNsBridge.swift')
SUFFIXES = {'.dart', '.java', '.kt', '.gradle', '.xml', '.swift', '.podspec', '.h', '.m', '.mm', '.md', '.plist', '.xcprivacy'}
# Repository-relative paths only; absolute GitHub URLs keep pointing at the repository.
RELATIVE = r'(?<![\w/.-])'


def package_path(path):
    text = path.as_posix()
    if text.startswith('docs/'):
        return pathlib.Path('doc/guides') / path.relative_to('docs')
    if text.startswith('examples/push_adapters/'):
        return pathlib.Path('example/push_adapters') / path.relative_to('examples/push_adapters')
    return path


def screenshot_paths(pubspec):
    entries = pubspec.get('screenshots', [])
    if not isinstance(entries, list):
        raise ValueError('pubspec screenshots must be a list.')
    for entry in entries:
        name = entry.get('path') if isinstance(entry, dict) else None
        if not isinstance(name, str):
            raise ValueError('Each pubspec screenshot needs a path.')
        path = pathlib.PurePosixPath(name)
        if (path.parts[:1] != ('screenshots',) or path.suffix != '.png'
                or any(part.startswith('.') for part in path.parts)):
            raise ValueError('Screenshot paths must name PNG files under screenshots/.')
        yield path


def stage(source, destination):
    source, destination = source.resolve(), destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('Candidate must be outside the source checkout.')
    if destination.exists():
        raise ValueError('Candidate destination must not already exist.')
    files = []
    for name in ROOT_FILES + PUBLIC_GUIDES + EXTRA_FILES:
        path = source / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'Missing or empty required file: {name}')
        files.append(path)
    for name in SOURCE_TREES:
        tree = source / name
        if tree.is_symlink() or any(parent.is_symlink() for parent in tree.parents if parent != source):
            raise ValueError('Linked source directories are not allowed.')
        if not tree.is_dir():
            raise ValueError(f'Missing required source directory: {name}')
        for path in tree.rglob('*'):
            relative = path.relative_to(source)
            if any(part.startswith('.') or part in {'build', 'Pods', 'ephemeral'} for part in relative.parts):
                continue
            if path.is_symlink():
                raise ValueError('Symlinks are not allowed in release source trees.')
            if path.is_file() and path.suffix in SUFFIXES:
                files.append(path)
    # Ruby provides a safe YAML parser on the macOS and Linux release runners.
    manifest_path = source / 'pubspec.yaml'
    if manifest_path.is_symlink():
        raise ValueError('Linked pubspec.yaml is not allowed.')
    result = subprocess.run(
        ['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read))'],
        input=manifest_path.read_text(), capture_output=True, text=True,
    )
    if result.returncode:
        raise ValueError('Invalid YAML in pubspec.yaml.')
    pubspec = json.loads(result.stdout)
    if not isinstance(pubspec, dict) or not isinstance(pubspec.get('version'), str):
        raise ValueError('pubspec.yaml needs a version.')
    for relative in screenshot_paths(pubspec):
        path = source / relative
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f'Missing or empty declared screenshot: {relative}')
        files.append(path)
    for path in files:
        if (path.is_symlink() or source not in path.resolve().parents
                or any(parent.is_symlink() for parent in path.parents if source in parent.parents)
                or path.stat().st_size > 2 * 1024 * 1024):
            raise ValueError('Unexpected linked or oversized release input.')
    if 'publish_to' in pubspec:
        raise ValueError('pubspec.yaml must not set publish_to; pub.dev verifies the repository copy.')
    version = pubspec['version']
    if not re.search(r'^## ' + re.escape(version) + r'$', (source / 'CHANGELOG.md').read_text(), re.M):
        raise ValueError('Version needs a matching changelog heading.')
    destination.mkdir(parents=True)
    for path in files:
        target = destination / package_path(path.relative_to(source))
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == '.md':
            text = re.sub(RELATIVE + 'docs/', 'doc/guides/', path.read_text())
            target.write_text(re.sub(RELATIVE + 'examples/push_adapters', 'example/push_adapters', text))
        else:
            shutil.copyfile(path, target)
    # Candidate examples are source snippets; complete native hosts/tests stay in the repository.
    return version, sorted(str(package_path(p.relative_to(source))) for p in files)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=pathlib.Path)
    args = parser.parse_args()
    try:
        version, files = stage(ROOT, args.destination)
    except (ValueError, OSError) as error:
        print(f'Release staging failed: {error}', file=sys.stderr)
        return 1
    print(f'Candidate {version}: {len(files)} allowlisted files. Nothing was published.')
    for path in files:
        print(path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
