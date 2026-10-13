"""Offline installer contract checks; no real runtime, model download or credentials."""
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("model_pull", Path(__file__).parents[1] / "tools/pull_local_model.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PullChecks(unittest.TestCase):
    def execute(self, replies, expected="pinned"):
        class Opener:
            def open(self, *_args, **_kwargs):
                return io.BytesIO(replies.pop(0))
        with tempfile.TemporaryDirectory() as directory:
            progress = Path(directory) / "progress.jsonl"
            with patch.object(module.urllib.request, "build_opener", return_value=Opener()), \
                    patch("sys.argv", ["pull_local_model.py", "fixture", "--digest", expected]), \
                    patch.dict(os.environ, {"AIE_INSTALL_PROGRESS_FILE": str(progress)}):
                module.main()
            if progress.exists():
                self.assertLess(progress.stat().st_size, 512)
                self.assertEqual(progress.stat().st_mode & 0o777, 0o600)

    def test_reuses_verified_model(self):
        replies = [b'{"models":[{"name":"fixture","digest":"pinned"}]}']
        self.execute(replies)
        self.assertFalse(replies)

    def test_stream_and_digest(self):
        self.execute([b'{"models":[]}',
                      b'{"total":100,"completed":30}\n{"status":"success"}\n',
                      b'{"models":[{"name":"fixture","digest":"pinned"}]}'])

    def test_rejects_partial_download(self):
        with self.assertRaises(RuntimeError):
            self.execute([b'{"models":[]}', b'{"total":100,"completed":30}\n'])

    def test_rejects_wrong_digest(self):
        with self.assertRaises(RuntimeError):
            self.execute([b'{"models":[]}', b'{"status":"success"}\n',
                          b'{"models":[{"name":"fixture","digest":"unexpected"}]}'])

    def test_rejects_runtime_error(self):
        with self.assertRaises(RuntimeError):
            self.execute([b'{"models":[]}', b'{"error":"fixture"}\n'])


if __name__ == "__main__":
    unittest.main()
