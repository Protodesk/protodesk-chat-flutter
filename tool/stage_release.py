#!/usr/bin/env python3
"""Build a minimal, inspectable pub.dev dry-run candidate. Never publishes."""
import argparse
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_FILES = ('.pubignore', 'pubspec.yaml', 'README.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE')
SOURCE_TREES = ('lib', 'android', 'ios', 'docs', 'example/lib', 'examples/push_adapters/lib')
EXTRA_FILES = ('example/README.md', 'example/pubspec.yaml', 'examples/push_adapters/README.md', 'examples/push_adapters/pubspec.yaml', 'examples/push_adapters/ios/ChatAPNsBridge.swift')
SUFFIXES = {'.dart', '.java', '.kt', '.gradle', '.xml', '.swift', '.podspec', '.h', '.m', '.mm', '.md', '.plist', '.xcprivacy'}


def package_path(path):
    text = path.as_posix()
    if text.startswith('docs/'):
        return pathlib.Path('doc/guides') / path.relative_to('docs')
    if text.startswith('examples/push_adapters/'):
        return pathlib.Path('example/push_adapters') / path.relative_to('examples/push_adapters')
    return path


def stage(source, destination):
    source, destination = source.resolve(), destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('Candidate must be outside the source checkout.')
    if destination.exists():
        raise ValueError('Candidate destination must not already exist.')
    files = []
    for name in ROOT_FILES + EXTRA_FILES:
        path = source / name
        if path.exists():
            files.append(path)
    for name in SOURCE_TREES:
        tree = source / name
        if tree.is_symlink() or any(parent.is_symlink() for parent in tree.parents if parent != source):
            raise ValueError('Linked source directories are not allowed.')
        if not tree.exists():
            continue
        for path in tree.rglob('*'):
            relative = path.relative_to(source)
            if any(part.startswith('.') or part in {'build', 'Pods', 'ephemeral'} for part in relative.parts):
                continue
            if path.is_symlink():
                raise ValueError('Symlinks are not allowed in release source trees.')
            if path.is_file() and path.suffix in SUFFIXES:
                files.append(path)
    for path in files:
        if (path.is_symlink() or source not in path.resolve().parents
                or any(parent.is_symlink() for parent in path.parents if source in parent.parents)
                or path.stat().st_size > 2 * 1024 * 1024):
            raise ValueError('Unexpected linked or oversized release input.')
    pubspec = (source / 'pubspec.yaml').read_text()
    if re.search(r'^publish_to:', pubspec, re.M):
        raise ValueError('pubspec.yaml must not set publish_to; pub.dev verifies the repository copy.')
    version = re.search(r'^version: (\S+)$', pubspec, re.M).group(1)
    if not re.search(r'^## ' + re.escape(version) + r'$', (source / 'CHANGELOG.md').read_text(), re.M):
        raise ValueError('Version needs a matching changelog heading.')
    destination.mkdir(parents=True)
    for path in files:
        target = destination / package_path(path.relative_to(source))
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == '.md':
            target.write_text(path.read_text().replace('docs/', 'doc/guides/').replace('examples/push_adapters', 'example/push_adapters'))
        else:
            shutil.copyfile(path, target)
    (destination / 'pubspec.yaml').write_text(pubspec)
    # Candidate examples are source snippets; complete native hosts/tests stay in the repository.
    return version, sorted(str(package_path(p.relative_to(source))) for p in files)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=pathlib.Path)
    args = parser.parse_args()
    try:
        version, files = stage(ROOT, args.destination)
    except (ValueError, OSError) as error:
        print(f'Release staging failed: {type(error).__name__}', file=sys.stderr)
        return 1
    print(f'Candidate {version}: {len(files)} allowlisted files. Nothing was published.')
    for path in files:
        print(path)
    if not (ROOT / 'LICENSE').exists():
        print('BLOCKER: approved LICENSE is missing; dry-run must not be treated as release approval.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
