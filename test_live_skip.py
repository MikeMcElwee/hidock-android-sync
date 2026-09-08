#!/usr/bin/env python3
"""Unit tests for mid-record live-file skip (no USB / hidock-next required).

Run: python -m unittest test_live_skip
"""
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path


def _stub_hidock_next(tmpdir):
    src = Path(tmpdir) / "hidock-next" / "apps" / "desktop" / "src"
    src.mkdir(parents=True)
    (src / "hidock_device.py").write_text("class HiDockJensen:\n    pass\n")
    return Path(tmpdir) / "hidock-next"


def _stub_pyusb():
    for name in ("usb", "usb.core", "usb.util", "usb.backend", "usb.backend.libusb1"):
        sys.modules.setdefault(name, types.ModuleType(name))


class _Jensen:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    def get_recording_file(self, timeout_s=5):
        self.calls.append(timeout_s)
        if self.error is not None:
            raise self.error
        return self.result


class LiveSkipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        nxt = _stub_hidock_next(cls._tmp.name)
        os.environ["HIDOCK_NEXT_DIR"] = str(nxt)
        _stub_pyusb()
        repo = Path(__file__).resolve().parent
        if str(repo) not in sys.path:
            sys.path.insert(0, str(repo))
        import hidock_sync as hs  # noqa: E402
        cls.hs = hs

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_resolve_name(self):
        self.assertEqual(self.hs.resolve_live_skip_name({"name": "foo.hda"}), "foo.hda")

    def test_resolve_basename(self):
        self.assertEqual(
            self.hs.resolve_live_skip_name({"name": "/rec/foo.hda"}), "foo.hda"
        )

    def test_resolve_fail_open(self):
        self.assertIsNone(self.hs.resolve_live_skip_name(None))
        self.assertIsNone(self.hs.resolve_live_skip_name({}))
        self.assertIsNone(self.hs.resolve_live_skip_name({"name": ""}))
        self.assertIsNone(self.hs.resolve_live_skip_name({"name": "   "}))
        self.assertIsNone(self.hs.resolve_live_skip_name("foo.hda"))

    def test_query_ok(self):
        j = _Jensen({"name": "live.hda", "status": "recording_active_or_last"})
        self.assertEqual(self.hs.query_live_skip_name(j, timeout_s=5), "live.hda")
        self.assertEqual(j.calls, [5])

    def test_query_raises_fail_open(self):
        j = _Jensen(error=RuntimeError("usb timeout"))
        self.assertIsNone(self.hs.query_live_skip_name(j))

    def test_query_none_fail_open(self):
        self.assertIsNone(self.hs.query_live_skip_name(_Jensen(None)))

    def test_is_live_skip(self):
        self.assertTrue(self.hs.is_live_skip("foo.hda", "foo.hda"))
        self.assertTrue(self.hs.is_live_skip("/x/foo.hda", "foo.hda"))
        self.assertFalse(self.hs.is_live_skip("bar.hda", "foo.hda"))
        self.assertFalse(self.hs.is_live_skip("foo.hda", None))
        self.assertFalse(self.hs.is_live_skip("foo.hda", ""))


if __name__ == "__main__":
    unittest.main()
