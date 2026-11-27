"""No pipeline under pipefail ends in a reader that stops early.

The rules -- what counts as a pipeline, and which readers stop early -- are
``scripts/pipefail-readers.py``, which adopters vendor to scan their own
shell; its docstring says why each one is there. Its doctests run here.

This holds canonical's own files to it:

- every workflow this repo runs (``.github/workflows``) and every one it
  publishes for adopters to vendor (``github/workflows``). A step runs under
  pipefail when it sets it or names ``shell: bash`` (GitHub's ``bash -eo
  pipefail``); the rest are held too, since adding either later is one line
  and would arm the race silently;
- each ``scripts/*.sh`` that sets pipefail;
- NOT ``standard.mk``: make runs a recipe under ``/bin/sh -c`` with no
  pipefail, so a pipeline's status there is its last command's, and an
  early reader cannot fail it.

Every file in scope is read, so a new step or script is covered without
being listed.
"""

from __future__ import annotations

import contextlib
import doctest
import importlib.util
import io
import pathlib
import tempfile
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW_DIRS = (ROOT / ".github" / "workflows", ROOT / "github" / "workflows")
SCRIPTS = ROOT / "scripts"
SCRIPT = SCRIPTS / "pipefail-readers.py"

_spec = importlib.util.spec_from_file_location("pipefail_readers", SCRIPT)
assert _spec is not None and _spec.loader is not None
pr: Any = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pr)


def scope() -> "list[pathlib.Path]":
    """Every file the scan reads."""
    files = [p for d in WORKFLOW_DIRS for p in sorted(d.glob("*.yml"))]
    files += [
        p
        for p in sorted(SCRIPTS.glob("*.sh"))
        if pr.PIPEFAIL.search(p.read_text(encoding="utf-8"))
    ]
    return files


def run(*argv: str) -> "tuple[int, str]":
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = pr.main(list(argv))
    return rc, out.getvalue()


class NoEarlyReaderPipe(unittest.TestCase):
    def test_the_scan_reads_each_place(self) -> None:
        # A scope that read nothing has checked nothing, in any of the three.
        files = scope()
        for where in (*WORKFLOW_DIRS, SCRIPTS):
            self.assertTrue(
                [p for p in files if p.parent == where],
                f"the scan read nothing under {where}",
            )

    def test_no_pipeline_ends_in_an_early_reader(self) -> None:
        rc, out = run(*(str(p) for p in scope()))
        self.assertEqual(rc, 0, out)


class TheCommandLine(unittest.TestCase):
    """What an adopter's make target runs."""

    def setUp(self) -> None:
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.dir = pathlib.Path(d.name)

    def file(self, name: str, text: str) -> str:
        (self.dir / name).write_text(text, encoding="utf-8")
        return str(self.dir / name)

    def test_an_offender_is_named_and_red(self) -> None:
        f = self.file("a.sh", "set -euo pipefail\nx | grep -q y\n")
        rc, out = run("--pipefail-only", f)
        self.assertEqual(rc, 1)
        self.assertIn(f"{f}:2: x | grep -q y", out)

    def test_a_clean_file_passes_and_counts(self) -> None:
        f = self.file("a.sh", "set -euo pipefail\nx | grep y >/dev/null\n")
        self.assertEqual(run("--pipefail-only", f)[0], 0)

    def test_a_workflow_is_read_without_a_set_pipefail(self) -> None:
        # `shell: bash` is pipefail, with no `set` line to see.
        f = self.file("ci.yml", "    steps:\n      - run: x | head -1\n")
        rc, out = run("--pipefail-only", f)
        self.assertEqual(rc, 1, out)

    def test_scanning_nothing_is_not_a_pass(self) -> None:
        f = self.file("a.sh", "x | grep -q y\n")
        rc, out = run("--pipefail-only", f)
        self.assertEqual(rc, 2, out)
        self.assertIn("scanned no file", out)
        self.assertEqual(run()[0], 2)


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    tests.addTests(doctest.DocTestSuite(pr))
    return tests


if __name__ == "__main__":
    unittest.main()
