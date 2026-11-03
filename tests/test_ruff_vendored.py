"""standard.mk makes an adopter's ruff skip every vendored Python file.

A vendored file is held byte-for-byte by standard-check, so an adopter's
``make lint`` running ``ruff check --fix`` / ``ruff format`` over it is a
guaranteed drift failure. Every adopter kept a hand-written exclude list
for this, and the lists drifted: canonical #184 changed scripts/train.py,
and hunterdsp/mcp-store's re-vendor PR 109 went red when ruff rewrote it.

So standard.mk appends ``$(STD_RUFF_EXCLUDE)`` to LINT_ruff and
LINT_ruff-format, derived from VENDORED_FILES. ``Wiring`` drives make in a
fixture adopter and reads what each target would run; ``RealRuff`` runs the
targets with a real ruff over badly formatted files and checks which ones it
rewrote. RealRuff needs ``ruff`` on PATH and, like the jq tests (#121),
FAILS naming it when it is absent rather than skipping into an OK.
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

BASE = (
    "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\nCLEAN_PATHS = dist/\n"
    "RUFF = ruff\nLINT_TOOLS = ruff ruff-format\n"
)

# Formatted wrongly in every way ruff format and isort (I001) can see.
BAD = "import sys\nimport os\nx = (1,\n  2)\nprint(sys, os, x)\n"


class Adopter(unittest.TestCase):
    """A throwaway repo holding canonical's standard.mk and a Makefile."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")

    def makefile(self, body: str) -> None:
        (self.tmp / "Makefile").write_text(
            BASE + body + "include standard.mk\n"
        )

    def make(self, *args: str) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k != "MAKEFLAGS"}
        return subprocess.run(
            ["make", "--no-print-directory", "-s", "-C", str(self.tmp), *args],
            env=env,
            capture_output=True,
            text=True,
        )

    def vendored(self) -> list[str]:
        """What this adopter vendors, as its own make reports it."""
        p = self.make("standard-files")
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.split()[1:]  # the first line is standard.mk


class Wiring(Adopter):
    def recipe(self, target: str) -> str:
        p = self.make("-n", target)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def excluded(self, line: str) -> list[str]:
        """The paths of the one `--config 'extend-exclude=[...]'` in line."""
        found = re.findall(r"--config 'extend-exclude=\[([^]]*)\]'", line)
        self.assertEqual(len(found), 1, line)
        return re.findall(r'"([^"]*)"', found[0])

    def test_both_commands_skip_every_vendored_python_file(self) -> None:
        self.makefile(
            "VENDORED_FILES = tools/own.py tools/types.pyi docs/x.md\n"
            "HAS_CI_IMAGE = 1\nCI_IMAGE_REPO = ghcr.io/o/ci\n"
            "LINT_ruff = $(RUFF) check --fix .\n"
            "LINT_ruff-format = $(RUFF) format .\n"
        )
        vendored = self.vendored()
        want = sorted(f for f in vendored if f.endswith((".py", ".pyi")))
        # Armed: the adopter's own entries and canonical's are both there.
        for f in ("tools/own.py", "tools/types.pyi", "scripts/train.py"):
            self.assertIn(f, want)
        for target, head in (
            ("lint-ruff", "ruff check --fix ."),
            ("lint-ruff-format", "ruff format ."),
        ):
            line = self.recipe(target)
            self.assertTrue(line.startswith(head + " "), line)
            self.assertIn(" --force-exclude", line)
            self.assertEqual(self.excluded(line), want)
            # A non-Python vendored file is no business of ruff's.
            others = [f for f in vendored if f not in want]
            self.assertIn("docs/x.md", others)
            self.assertIn("docker/ci.Dockerfile", others)
            for f in others:
                self.assertNotIn(f, line)

    def test_a_simply_expanded_command_sees_the_whole_list(self) -> None:
        # `:=` expands when appended to, so the append must sit after the
        # last `VENDORED_FILES +=` in standard.mk.
        self.makefile(
            "LINT_ruff := $(RUFF) check .\n"
            "LINT_ruff-format := $(RUFF) format .\n"
        )
        want = sorted(f for f in self.vendored() if f.endswith(".py"))
        self.assertIn("scripts/close-keywords.py", want)
        for target in ("lint-ruff", "lint-ruff-format"):
            self.assertEqual(self.excluded(self.recipe(target)), want)

    def test_a_command_that_places_it_itself_is_not_doubled(self) -> None:
        self.makefile(
            "define LINT_ruff\n"
            "$(RUFF) check $(STD_RUFF_EXCLUDE) .\n"
            "@echo done\n"
            "endef\n"
            "LINT_ruff-format = $(RUFF) format .\n"
        )
        lines = self.recipe("lint-ruff").splitlines()
        self.assertEqual(lines[1], "echo done")
        self.assertEqual(lines[0].count("--force-exclude"), 1, lines)
        self.assertTrue(lines[0].endswith(" ."), lines)

    def test_an_unset_command_stays_unset(self) -> None:
        self.makefile("LINT_TOOLS = ruff\nLINT_ruff = $(RUFF) check .\n")
        p = self.make("-p")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotRegex(p.stdout, r"(?m)^LINT_ruff-format\b")
        self.assertIn("--force-exclude", self.recipe("lint-ruff"))


class RealRuff(Adopter):
    """What ruff actually rewrites under each command shape."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        if shutil.which("ruff") is None:
            raise RuntimeError(
                "ruff is not on PATH: these tests run the adopter's "
                "lint-ruff and lint-ruff-format with a real ruff, and "
                "cannot show without one that it leaves a vendored file "
                "alone. Install ruff (CI does: `pip install ruff`)."
            )

    def setUp(self) -> None:
        super().setUp()
        # A pyproject extend-exclude of the adopter's own, which the CLI
        # value must add to rather than replace.
        (self.tmp / "pyproject.toml").write_text(
            '[tool.ruff]\nextend-exclude = ["legacy/old.py"]\n'
            '[tool.ruff.lint]\nextend-select = ["I"]\n'
        )
        self.files = {
            "vendored": "scripts/train.py",
            "configured": "legacy/old.py",
            "own": "src/own.py",
        }
        self.reset()

    def reset(self) -> None:
        for rel in self.files.values():
            (self.tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.tmp / rel).write_text(BAD)

    def run_target(self, target: str) -> dict[str, bool]:
        p = self.make(target)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return {
            k: (self.tmp / rel).read_text() != BAD
            for k, rel in self.files.items()
        }

    def test_format_and_fix_leave_vendored_and_configured_alone(self) -> None:
        self.makefile(
            "LINT_ruff = $(RUFF) check --fix --unsafe-fixes .\n"
            "LINT_ruff-format = $(RUFF) format .\n"
        )
        for target in ("lint-ruff", "lint-ruff-format"):
            with self.subTest(target=target):
                self.reset()
                self.assertEqual(
                    self.run_target(target),
                    # Armed: ruff did rewrite the adopter's own file.
                    {"vendored": False, "configured": False, "own": True},
                )

    def test_a_vendored_path_named_on_the_command_line(self) -> None:
        # ruff formats a path it is handed unless --force-exclude.
        self.makefile(
            "LINT_ruff = $(RUFF) check --fix scripts/train.py src\n"
            "LINT_ruff-format = $(RUFF) format scripts/train.py src\n"
        )
        for target in ("lint-ruff", "lint-ruff-format"):
            with self.subTest(target=target):
                self.reset()
                changed = self.run_target(target)
                self.assertFalse(changed["vendored"], target)
                self.assertTrue(changed["own"], target)


if __name__ == "__main__":
    unittest.main()
