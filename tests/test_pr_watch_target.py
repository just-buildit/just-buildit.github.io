"""standard.mk's ``pr-watch`` target, and the script it vendors (just-makeit#1818).

``HAS_PR_WATCH = 1`` must do two things together: define ``make pr-watch``
and put ``scripts/pr-watch.sh`` in ``VENDORED_FILES``. Apart, they are the
fork the issue is about -- a target per repo around a hand copy of the
script, which missed the REPO derivation and the stuck-run detector.

Each test builds a throwaway repo: this ``standard.mk``, a minimal Makefile,
and a STUB ``scripts/pr-watch.sh`` that prints the argument and the
environment it was given. So what is tested is the target's wiring -- does
``PR=`` and a command-line ``TIMEOUT_MIN=`` reach the script -- not the
script, which test_pr_watch.py covers. Stdlib only; needs GNU make.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STUB = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    echo "stub-pr=$1"
    echo "stub-timeout=${TIMEOUT_MIN:-unset}"
    echo "stub-advisory=${ADVISORY:-unset}"
    """
)


class PrWatchTarget(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")
        (self.tmp / "scripts").mkdir()
        (self.tmp / "scripts" / "pr-watch.sh").write_text(STUB)

    def make(self, *args: str, flag: bool = True):
        (self.tmp / "Makefile").write_text(
            ("HAS_PR_WATCH = 1\n" if flag else "")
            + "TEST_CMD = @echo test\n"
            + "TEST_FAST_CMD = @echo test-fast\n"
            + "CLEAN_PATHS = dist/\n"
            + "include standard.mk\n"
        )
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("PR", "TIMEOUT_MIN", "ADVISORY", "MAKEFLAGS")
        }
        return subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.tmp), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def test_the_flag_vendors_the_script(self) -> None:
        on = self.make("-s", "standard-files")
        self.assertEqual(on.returncode, 0, on.stderr)
        self.assertIn("scripts/pr-watch.sh", on.stdout.split())

    def test_without_the_flag_neither_exists(self) -> None:
        off = self.make("-s", "standard-files", flag=False)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertNotIn("scripts/pr-watch.sh", off.stdout.split())
        r = self.make("pr-watch", "PR=5", flag=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("stub-pr", r.stdout)

    def test_pr_and_a_command_line_setting_reach_the_script(self) -> None:
        r = self.make("pr-watch", "PR=1812", "TIMEOUT_MIN=90")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("stub-pr=1812", r.stdout)
        self.assertIn("stub-timeout=90", r.stdout)
        # Unset stays unset, so the script's own default applies.
        self.assertIn("stub-advisory=unset", r.stdout)

    def test_no_pr_is_a_usage_error_not_a_run(self) -> None:
        r = self.make("pr-watch")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("usage: make pr-watch PR=<number>", r.stdout)
        self.assertNotIn("stub-pr", r.stdout)

    def test_help_files_it_with_the_release_targets(self) -> None:
        r = self.make("help")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        at = next(i for i, ln in enumerate(lines) if "pr-watch" in ln)
        headings = [ln for ln in lines[:at] if ln.rstrip().endswith(":")]
        self.assertTrue(headings, r.stdout)
        self.assertIn("Release", headings[-1])

    def test_the_gates_hold_with_the_flag_on(self) -> None:
        r = self.make("help-check", "ghost-check")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_script_is_vendored_only_under_the_flag(self) -> None:
        mk = (ROOT / "standard.mk").read_text(encoding="utf-8")
        block = mk[mk.index("ifeq ($(HAS_PR_WATCH),1)") :]
        block = block[: block.index("\nendif")]
        self.assertIn("VENDORED_FILES += scripts/pr-watch.sh", block)
        self.assertIn("STD_TARGETS    += pr-watch", block)
        rest = mk.replace(block, "")
        self.assertNotIn("scripts/pr-watch.sh", rest)
        self.assertTrue((ROOT / "scripts" / "pr-watch.sh").exists())


if __name__ == "__main__":
    unittest.main()
