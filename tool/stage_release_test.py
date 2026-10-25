import pathlib
import tempfile
import unittest
from stage_release import stage


class StageTest(unittest.TestCase):
    def fixture(self, root):
        (root / 'pubspec.yaml').write_text('name: sample\nversion: 1.0.0-dev.1\n')
        (root / 'CHANGELOG.md').write_text('## 1.0.0-dev.1\n')
        (root / 'lib').mkdir()
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
            self.assertEqual(files, ['CHANGELOG.md', 'lib/main.dart', 'pubspec.yaml'])
            self.assertNotIn('publish_to:', (target / 'pubspec.yaml').read_text())
            with self.assertRaises(ValueError):
                stage(root, target)

    def test_maps_guides_and_rejects_linked_extra_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / 'source'
            root.mkdir()
            self.fixture(root)
            (root / 'docs').mkdir()
            (root / 'docs' / 'guide.md').write_text('See docs/guide.md')
            target = pathlib.Path(directory) / 'candidate'
            stage(root, target)
            self.assertEqual((target / 'doc/guides/guide.md').read_text(),
                             'See doc/guides/guide.md')
            outside = pathlib.Path(directory) / 'outside'
            outside.mkdir()
            (outside / 'README.md').write_text('private')
            (root / 'example').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                stage(root, pathlib.Path(directory) / 'rejected')

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
