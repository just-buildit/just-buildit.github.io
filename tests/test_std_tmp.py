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

    #: Any reference to a temp macro, in either make spelling. The
    #: definitions' own ``$(_STD_TMP_REFUSE)`` is a different name.
    USE = re.compile(r"\$[({]_STD_TMP(?:DIR(?:_QUIET)?)?[)}]")
    #: The definitions themselves, the one place mktemp is spelled.
    DEFINED = re.compile(r"_STD_TMP(?:DIR(?:_QUIET)?)? = ")
    #: What must follow it: the command substitution closing, then a
    #: failure handler. ``say true`` is ci-changes' fail-safe answer.
    HANDLED = re.compile(r"\s*\)\s*\|\|\s*(?:exit 1|say true)\b")

    def setUp(self) -> None:
        # Comment lines describe the rule, and may quote it; only code
        # counts. A recipe is one shell command across its backslash
        # continuations, so each logical line is read whole (kept with the
        # number of its first line): a handler on the next line counts.
        self.code: list[tuple[int, str]] = []
        held, first = "", 0
        for n, line in enumerate(STD.read_text().splitlines(), 1):
            if not held and line.lstrip().startswith("#"):
                continue
            if not held:
                first = n
            if line.endswith("\\"):
                held += line[:-1] + " "
                continue
            self.code.append((first, held + line))
            held = ""

    def test_mktemp_only_in_the_two_definitions(self) -> None:
        stray = [
            f"standard.mk:{n}: {line.strip()[:120]}"
            for n, line in self.code
            if "mktemp" in line
            and not self.DEFINED.match(line)
        ]
        self.assertEqual(stray, [], "use $(_STD_TMP) / $(_STD_TMPDIR)")

    def unhandled(self, line: str) -> list[str]:
        """Each use of the macros in ``line`` with no failure handler."""
        bad = []
        for m in self.USE.finditer(line):
            h = self.HANDLED.match(line[m.end():])
            say = h is not None and "say true" in h.group(0)
            # `say` exists only in the recipe that defines it; and the QUIET
            # macro prints nothing, so only `say` (which prints why) may
            # follow it: a bare `|| exit 1` would fail with no word of why.
            if (
                not h
                or (say and "say() {" not in line)
                or ("_QUIET" in m.group(0) and not say)
            ):
                bad.append(line[m.start():][:80])
        return bad

    def test_every_use_handles_a_failed_mktemp(self) -> None:
        uses = 0
        bad = []
        for n, line in self.code:
            if self.DEFINED.match(line):
                continue
            uses += len(self.USE.findall(line))
            bad += [f"standard.mk:{n}: {b}" for b in self.unhandled(line)]
        # A walk that found nothing has checked nothing.
        self.assertGreater(uses, 0, "found no $(_STD_TMP) use at all")
        self.assertEqual(bad, [], "write x=$$($(_STD_TMP)) || exit 1;")

    def test_the_scan_reads_every_spelling(self) -> None:
        # The scan itself, on the shapes a hand edit could produce.
        ok = [
            "x=$$($(_STD_TMP)) || exit 1;",
            "x=$$($(_STD_TMPDIR) ) || exit 1;",
            "x=$$(${_STD_TMP})||exit 1",
            "say() { exit 0; }; x=$$($(_STD_TMPDIR)) || say true why",
            "say() { exit 0; }; x=$$($(_STD_TMPDIR_QUIET)) || say true y",
        ]
        red = [
            "x=$$($(_STD_TMPDIR_QUIET)) || exit 1;",
            "x=$$($(_STD_TMP));",
            "x=$$($(_STD_TMPDIR) );",
            "x=$$(${_STD_TMP}) || true;",
            "x=$$($(_STD_TMP) 2>/dev/null) || exit 1;",
            "x=$$($(_STD_TMPDIR)) || say true why",
        ]
        self.assertTrue(all(self.USE.search(t) for t in ok + red))
        for text in ok + red:
            with self.subTest(text=text):
                self.assertEqual(self.unhandled(text) == [], text in ok)


if __name__ == "__main__":
    unittest.main()
