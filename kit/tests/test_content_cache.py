"""A changed input or damaged output must never reuse a generated tree."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))
import content_cache


class ContentCacheTests(unittest.TestCase):
    def test_changed_added_and_missing_outputs_invalidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "chunk.c"
            source.write_text("original")
            content_cache.stamp(root, "key")
            self.assertTrue(content_cache.valid(root, "key"))
            self.assertFalse(content_cache.valid(root, "different inputs"))
            source.write_text("corrupted")
            self.assertFalse(content_cache.valid(root, "key"))
            source.write_text("original")
            extra = root / "extra.c"
            extra.write_text("unexpected")
            self.assertFalse(content_cache.valid(root, "key"))
            extra.unlink()
            source.unlink()
            self.assertFalse(content_cache.valid(root, "key"))

    def test_invalid_manifest_and_symlinks_are_not_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / content_cache.MANIFEST).write_text("[]")
            self.assertFalse(content_cache.valid(root, "key"))
            (root / "source.c").write_text("code")
            (root / "link.c").symlink_to(root / "source.c")
            with self.assertRaises(ValueError):
                content_cache.stamp(root, "key")

    def test_fingerprint_tracks_content_and_settings_not_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.py"
            source.write_text("one")
            key = content_cache.fingerprint([source], {"option": 1})
            source.touch()
            self.assertEqual(key, content_cache.fingerprint([source], {"option": 1}))
            self.assertNotEqual(key, content_cache.fingerprint([source], {"option": 2}))
            source.write_text("two")
            self.assertNotEqual(key, content_cache.fingerprint([source], {"option": 1}))
