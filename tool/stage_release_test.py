import pathlib
import tempfile
import unittest
from stage_release import EXTRA_FILES, PUBLIC_GUIDES, ROOT_FILES, SOURCE_TREES, stage


class StageTest(unittest.TestCase):
    def fixture(self, root):
        for name in ROOT_FILES + PUBLIC_GUIDES + EXTRA_FILES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture\n')
        for name in SOURCE_TREES:
            (root / name).mkdir(parents=True, exist_ok=True)
        (root / 'pubspec.yaml').write_text('name: sample\nversion: 1.0.0-dev.1\n')
        (root / 'CHANGELOG.md').write_text('## 1.0.0-dev.1\n')
        (root / 'lib' / 'main.dart').write_text('// public source\n')

    def test_stage_isolated_and_excludes_local_build_and_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            (root / '.env').write_text('SECRET')
            (root / 'lib' / 'key.pem').write_text('SECRET')
            (root / 'build').mkdir()
            (root / 'build' / 'binary.dart').write_text('SECRET')
            target = pathlib.Path(directory) / 'candidate'
            _, files = stage(root, target)
            self.assertIn('lib/main.dart', files)
            for excluded in ('.env', 'lib/key.pem', 'build/binary.dart'):
                self.assertNotIn(excluded, files)
            self.assertNotIn('publish_to:', (target / 'pubspec.yaml').read_text())
            with self.assertRaises(ValueError):
                stage(root, target)

    def test_maps_guides_and_rejects_linked_extra_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            (root / 'docs' / 'guide.md').write_text('See docs/guide.md')
            (root / 'docs' / 'testing.md').write_text('Repository test instructions')
            target = pathlib.Path(directory) / 'candidate'
            stage(root, target)
            self.assertFalse((target / 'doc/guides/testing.md').exists())
            self.assertEqual((target / 'doc/guides/guide.md').read_text(),
                             'See doc/guides/guide.md')
            url = 'https://github.com/o/r/blob/main/docs/guide.md'
            (root / 'README.md').write_text(f'[guide]({url}) and docs/guide.md')
            stage(root, pathlib.Path(directory) / 'with-readme')
            self.assertEqual((pathlib.Path(directory) / 'with-readme/README.md').read_text(),
                             f'[guide]({url}) and doc/guides/guide.md')
            outside = pathlib.Path(directory) / 'outside'
            (root / 'example').rename(outside)
            (root / 'example').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                stage(root, pathlib.Path(directory) / 'rejected')

    def test_requires_explicit_release_files_before_creating_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            target = root.parent / 'candidate'
            for name in ('NOTICE', 'LICENSE', 'assets/fonts/OFL.txt', 'docs/guide.md'):
                with self.subTest(name=name):
                    path = root / name
                    path.unlink()
                    with self.assertRaisesRegex(ValueError, name):
                        stage(root, target)
                    self.assertFalse(target.exists())
                    path.write_text('fixture\n')

    def test_stages_only_declared_screenshots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            gallery = root / 'screenshots'
            gallery.mkdir()
            (gallery / 'home.png').write_bytes(b'home')
            (gallery / 'dark-offline.png').write_bytes(b'legacy')
            manifest = root / 'pubspec.yaml'
            original = manifest.read_text()
            manifest.write_text(original + 'screenshots:\n  - path: "screenshots/home.png"\n')
            target = root.parent / 'candidate'
            _, files = stage(root, target)
            self.assertEqual([p for p in files if p.startswith('screenshots/')], ['screenshots/home.png'])
            self.assertFalse((target / 'screenshots/dark-offline.png').exists())
            for path in ('screenshots/missing.png', 'screenshots/../hidden.png', '/tmp/hidden.png'):
                with self.subTest(path=path):
                    manifest.write_text(original + f'screenshots: [{{path: "{path}"}}]\n')
                    with self.assertRaises(ValueError):
                        stage(root, root.parent / 'rejected')
                    self.assertFalse((root.parent / 'rejected').exists())

    def test_rejects_symlink_and_missing_changelog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            (root / 'lib' / 'leak.dart').symlink_to(root / 'pubspec.yaml')
            with self.assertRaises(ValueError):
                stage(root, pathlib.Path(directory) / 'candidate')
            (root / 'lib' / 'leak.dart').unlink()
            (root / 'CHANGELOG.md').write_text('## Wrong version\n')
            with self.assertRaises(ValueError):
                stage(root, pathlib.Path(directory) / 'candidate')

    def test_rejects_publish_to(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            (root / 'pubspec.yaml').write_text('name: sample\nversion: 1.0.0-dev.1\npublish_to: none\n')
            with self.assertRaises(ValueError):
                stage(root, pathlib.Path(directory) / 'candidate')


if __name__ == '__main__':
    unittest.main()
