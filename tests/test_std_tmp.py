"""A gate whose temp file cannot be made says so (just-buildit.github.io#251).

Every recipe in ``standard.mk`` that needs a temp file or directory gets it
from ``_STD_TMP`` / ``_STD_TMPDIR``, written ``x=$$($(_STD_TMP)) || exit 1``.
When ``mktemp`` fails -- ``TMPDIR`` names a directory that does not exist --
the recipe refuses right there, naming the temp directory, before it fetches
or compares anything.

Before, ``tmp=$$(mktemp)`` came back empty, ``curl -o ""`` failed, and
``standard-check`` printed ``ERROR: cannot fetch <url>`` / "Fix the fetch"
for every vendored file: a local temp-dir problem read as a CDN outage. The
gate must still FAIL; only the diagnosis changes.

Two halves. The behavior: each gate run under a missing ``TMPDIR`` fails,
names it, and never says "cannot fetch". The form: every ``mktemp`` in the
file is inside the two definitions, and every use of them is followed by
``|| exit 1``, so a new recipe cannot reintroduce the silent empty path that
the behavior tests do not happen to run. Stdlib only; needs GNU make.
"""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
STD = ROOT / "standard.mk"


class MissingTmpdir(unittest.TestCase):
    """Run gates against a hermetic ``file://`` canonical."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        canon = self.tmp / "canon"
        self.app = self.tmp / "app"
        canon.mkdir()
        self.app.mkdir()
        shutil.copy(STD, canon / "standard.mk")
        shutil.copy(STD, self.app / "standard.mk")
        (canon / "get-jb.sh").write_text("#!/bin/sh\necho jb\n")
        (self.app / "get-jb.sh").write_text("#!/bin/sh\necho jb\n")
        # `override` makes the list exactly this one file: standard.mk adds
        # the scripts every repo vendors, which this canonical does not hold.
        (self.app / "Makefile").write_text(
            "TEST_CMD = @echo test\n"
            "TEST_FAST_CMD = @echo test-fast\n"
            "CLEAN_PATHS = dist/\n"
            f"STANDARD_URL = file://{canon}/standard.mk\n"
            "override VENDORED_FILES = get-jb.sh\n"
            "include standard.mk\n"
        )
        self.missing = self.tmp / "no-such-dir"

    def make(self, target: str, tmpdir: pathlib.Path):
        env = {k: v for k, v in os.environ.items() if k != "MAKEFLAGS"}
        env["TMPDIR"] = str(tmpdir)
        return subprocess.run(
            ["make", "-s", "--no-print-directory", "-C", str(self.app),
             target],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def test_each_gate_passes_with_a_working_tmpdir(self) -> None:
        # The control: the same tree is green, so a red run below is the
        # temp directory and nothing else.
        for target in ("standard-check", "standard-update", "help-check",
                       "ghost-check"):
            with self.subTest(target=target):
                r = self.make(target, self.tmp)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_each_gate_refuses_naming_the_temp_dir(self) -> None:
        for target in ("standard-check", "standard-update", "help-check",
                       "ghost-check"):
            with self.subTest(target=target):
                r = self.make(target, self.missing)
                out = r.stdout + r.stderr
                self.assertNotEqual(r.returncode, 0, out)
                self.assertIn(
                    f"cannot create a temp file in {self.missing}", out
                )
                self.assertNotIn("cannot fetch", out)
                self.assertNotIn("differs from", out)


class EverySiteRefuses(unittest.TestCase):
    """The form every temp-file site in standard.mk must take."""

    def setUp(self) -> None:
        # Comment lines describe the rule, and may quote it; only code counts.
        self.code = [
            (n, line)
            for n, line in enumerate(STD.read_text().splitlines(), 1)
            if not line.lstrip().startswith("#")
        ]

    def test_mktemp_only_in_the_two_definitions(self) -> None:
        stray = [
            f"standard.mk:{n}: {line.strip()}"
            for n, line in self.code
            if "mktemp" in line
            and not re.match(r"_STD_TMP(DIR)? = mktemp ", line)
        ]
        self.assertEqual(stray, [], "use $(_STD_TMP) / $(_STD_TMPDIR)")

    def test_every_use_exits_when_mktemp_fails(self) -> None:
        uses = 0
        bad = []
        for n, line in self.code:
            for m in re.finditer(r"\$\$\(\$\(_STD_TMP(DIR)?\)\)", line):
                uses += 1
                rest = line[m.end():]
                if not re.match(r"\s*\|\|\s*exit 1\s*;", rest):
                    bad.append(f"standard.mk:{n}: {line.strip()}")
        # A walk that found nothing has checked nothing.
        self.assertGreater(uses, 0, "found no $$($(_STD_TMP)) use at all")
        self.assertEqual(bad, [], "write x=$$($(_STD_TMP)) || exit 1;")


if __name__ == "__main__":
    unittest.main()
