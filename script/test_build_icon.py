#!/usr/bin/env python3
"""Exercise icon output ownership using an isolated fake actool."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().with_name("build_icon.sh")


class IconOutputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="screenrecall-icon-test-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.xcrun = self.bin / "xcrun"
        self.xcrun.write_text('''#!/bin/bash
set -eu
if [[ "${MOCK_ACTION:-}" == "wait" ]]; then
  echo ready > "$MOCK_READY"
  while :; do sleep 1; done
fi
if [[ "${MOCK_ACTION:-}" == "fail" ]]; then exit 42; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compile) out="$2"; shift 2 ;;
    --output-partial-info-plist) plist="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf assets > "$out/Assets.car"
printf icon > "$out/ScreenRecall.icns"
printf plist > "$plist"
''')
        self.xcrun.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TMPDIR=str(self.root))

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, output, action=""):
        return subprocess.run([str(SCRIPT), str(output)], env=dict(self.env, MOCK_ACTION=action),
                              capture_output=True, text=True, timeout=15)

    def test_existing_directory_and_symlink_are_untouched(self):
        existing = self.root / "existing"
        existing.mkdir()
        for name in ("Assets.car", "ScreenRecall.icns", "partial.plist"):
            (existing / name).write_text("keep")
        self.assertNotEqual(self.run_script(existing).returncode, 0)
        self.assertTrue(all((existing / name).read_text() == "keep" for name in
                            ("Assets.car", "ScreenRecall.icns", "partial.plist")))
        link = self.root / "dangling"
        link.symlink_to(self.root / "absent")
        self.assertNotEqual(self.run_script(link).returncode, 0)
        self.assertTrue(link.is_symlink())

    def test_fresh_output_and_failed_build_keep_separate_paths(self):
        output = self.root / "output"
        result = self.run_script(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("output=" + str(output), result.stdout)
        self.assertEqual((output / "Assets.car").read_text(), "assets")
        self.assertEqual((output / "ScreenRecall.icns").read_text(), "icon")
        self.assertEqual((output / "partial.plist").read_text(), "plist")
        failed = self.root / "failed"
        self.assertNotEqual(self.run_script(failed, "fail").returncode, 0)
        self.assertTrue(failed.is_dir())
        self.assertFalse(list(self.root.glob("screenrecall-catalog.*")))
        self.assertEqual((output / "Assets.car").read_text(), "assets")

    def test_term_cleans_owned_catalog(self):
        output = self.root / "term-output"
        ready = self.root / "ready"
        proc = subprocess.Popen([str(SCRIPT), str(output)], env=dict(self.env, MOCK_ACTION="wait", MOCK_READY=str(ready)),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                if proc.poll() is not None:
                    self.fail("mock actool exited before ready")
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            os.killpg(proc.pid, signal.SIGTERM)
            proc.communicate(timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(list(self.root.glob("screenrecall-catalog.*")))
            self.assertTrue(output.is_dir())
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate(timeout=10)

    def test_default_runs_use_distinct_outputs(self):
        source = self.root / "source"
        (source / "script").mkdir(parents=True)
        (source / "Resources/ScreenRecall.icon").mkdir(parents=True)
        (source / "Resources/ScreenRecall.icon/icon.json").write_text("{}")
        isolated = source / "script/build_icon.sh"
        shutil.copy2(SCRIPT, isolated)
        first = subprocess.run([str(isolated)], env=self.env, capture_output=True, text=True, timeout=15)
        second = subprocess.run([str(isolated)], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        first_output = Path(first.stdout.splitlines()[0].removeprefix("output="))
        second_output = Path(second.stdout.splitlines()[0].removeprefix("output="))
        self.assertNotEqual(first_output, second_output)
        self.assertEqual((first_output / "Assets.car").read_text(), "assets")
        self.assertEqual((second_output / "Assets.car").read_text(), "assets")


if __name__ == "__main__":
    unittest.main()
