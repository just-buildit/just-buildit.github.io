"""Behaviour of scripts/changelog.py, driven over real temporary git repos.

Stdlib only (unittest), like the script, so it runs anywhere canonical's CI
does with nothing installed: ``python3 -m unittest discover -s tests``.
Every case builds a ``main`` commit, branches, does what a contributor or a
release would do, and runs the script as the Makefile runs it.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "changelog.py"

BASE_CHANGELOG = textwrap.dedent(
    """\
    # Changelog

    ## [Unreleased]

    ## [1.0.0] — 2026-01-01

    ### Fixed

    - **Shipped fix.** It shipped.
    """
)


class Repo:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def write(self, rel: str, text: str) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def read(self, rel: str) -> str:
        return (self.root / rel).read_text(encoding="utf-8")

    def commit(self, msg: str = "c") -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.root,
            capture_output=True,
            text=True,
        )


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        r = Repo(pathlib.Path(self._tmp.name))
        r.git("init", "-q", "-b", "main")
        r.git("config", "user.email", "t@example.com")
        r.git("config", "user.name", "t")
        r.git("config", "commit.gpgsign", "false")
        r.write("CHANGELOG.md", BASE_CHANGELOG)
        r.write("src/a.py", "x = 1\n")
        r.write("changelog.d/README.md", "how to\n")
        r.commit("base")
        r.git("tag", "v1.0.0")
        r.git("checkout", "-q", "-b", "feature")
        self.r = r

    def check(self) -> subprocess.CompletedProcess:
        return self.r.run("check", "main", "src")

    def sections(self) -> subprocess.CompletedProcess:
        return self.r.run("sections", "main")

    def ok(self, p: subprocess.CompletedProcess) -> None:
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def bad(self, p: subprocess.CompletedProcess, *needles: str) -> None:
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        for n in needles:
            self.assertIn(n, p.stdout + p.stderr)


class Check(Base):
    def test_code_change_with_a_fragment_passes(self) -> None:
        self.r.write("src/a.py", "x = 2\n")
        self.r.write("changelog.d/fixed/x.md", "- **x is 2.** Was 1.\n")
        self.r.commit()
        self.ok(self.check())

    def test_code_change_without_a_fragment_fails(self) -> None:
        self.r.write("src/a.py", "x = 2\n")
        self.r.commit()
        self.bad(self.check(), "no fragment added", "src/a.py")

    def test_docs_only_branch_needs_no_fragment(self) -> None:
        self.r.write("README.md", "docs\n")
        self.r.commit()
        self.ok(self.check())

    def test_path_prefix_is_a_whole_component(self) -> None:
        self.r.write("srcfoo/b.py", "y = 1\n")
        self.r.commit()
        self.ok(self.check())

    def test_hand_written_unreleased_entry_fails(self) -> None:
        # Even WITH a fragment: the shared line is the churn, whatever else
        # the branch does right.
        self.r.write("src/a.py", "x = 2\n")
        self.r.write("changelog.d/fixed/x.md", "- **x.**\n")
        self.r.write(
            "CHANGELOG.md",
            BASE_CHANGELOG.replace(
                "## [Unreleased]\n", "## [Unreleased]\n\n- **by hand.**\n"
            ),
        )
        self.r.commit()
        self.bad(self.check(), "gained an entry by hand")

    def test_rewording_an_unreleased_entry_passes(self) -> None:
        base = BASE_CHANGELOG.replace(
            "## [Unreleased]\n", "## [Unreleased]\n\n- **old words.**\n"
        )
        self.r.git("checkout", "-q", "main")
        self.r.write("CHANGELOG.md", base)
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.r.write("CHANGELOG.md", base.replace("old words", "new words"))
        self.r.commit()
        self.ok(self.check())

    def test_fragment_without_a_bullet_fails(self) -> None:
        self.r.write("changelog.d/fixed/x.md", "prose, no bullet\n")
        self.r.commit()
        self.bad(self.check(), "does not start with '- '")

    def test_fragment_carrying_a_heading_fails(self) -> None:
        self.r.write("changelog.d/changed/x.md", "- **a.**\n\n### Removed\n")
        self.r.commit()
        self.bad(self.check(), "a heading", "### Removed")

    def test_fragment_in_an_unknown_section_fails(self) -> None:
        self.r.write("changelog.d/misc/x.md", "- **a.**\n")
        self.r.commit()
        self.bad(self.check(), "not in a section directory")

    def test_custom_sections_are_honoured(self) -> None:
        self.r.write("src/a.py", "x = 2\n")
        self.r.write("changelog.d/tooling/x.md", "- **a.**\n")
        self.r.commit()
        self.ok(self.r.run("--sections", "fixed tooling", "check", "main", "src"))

    def test_inert_with_uncommitted_code_fails(self) -> None:
        self.r.write("src/a.py", "x = 3\n")
        self.bad(self.check(), "uncommitted code changes")

    def test_inert_and_clean_passes(self) -> None:
        p = self.check()
        self.ok(p)
        self.assertIn("inert", p.stdout)

    def test_release_branch_assembly_passes(self) -> None:
        # A release moves fragments into CHANGELOG.md: [Unreleased] grows by
        # hand-count but fragments were consumed, which is the one writer.
        self.r.git("checkout", "-q", "main")
        self.r.write("changelog.d/fixed/x.md", "- **x.**\n")
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.ok(self.r.run("assemble", "--version", "1.1.0"))
        self.r.write("src/a.py", "__version__ = '1.1.0'\n")
        self.r.commit("release")
        self.ok(self.check())
        self.ok(self.sections())


class Assemble(Base):
    def test_promotes_deletes_and_is_idempotent(self) -> None:
        self.r.write("changelog.d/fixed/b.md", "- **b.**\n")
        self.r.write("changelog.d/fixed/a.md", "- **a.**\n    more\n")
        self.r.write("changelog.d/added/n.md", "- **new.**\n")
        self.ok(self.r.run("assemble"))
        text = self.r.read("CHANGELOG.md")
        body = text.split("## [Unreleased]\n", 1)[1].split("## [1.0.0]")[0]
        self.assertEqual(
            body,
            "\n### Added\n\n- **new.**\n\n### Fixed\n\n- **a.**\n    more\n\n"
            "- **b.**\n\n",
        )
        self.assertFalse((self.r.root / "changelog.d/fixed/a.md").exists())
        self.assertTrue((self.r.root / "changelog.d/README.md").exists())
        self.ok(self.r.run("assemble"))
        self.assertEqual(self.r.read("CHANGELOG.md"), text)

    def test_appends_after_an_existing_entry(self) -> None:
        self.r.write(
            "CHANGELOG.md",
            BASE_CHANGELOG.replace(
                "## [Unreleased]\n",
                "## [Unreleased]\n\n### Fixed\n\n- **first.**\n",
            ),
        )
        self.r.write("changelog.d/fixed/z.md", "- **second.**\n")
        self.ok(self.r.run("assemble"))
        text = self.r.read("CHANGELOG.md")
        self.assertLess(text.index("first."), text.index("second."))
        self.assertEqual(text.count("### Fixed"), 2)  # its own + 1.0.0's

    def test_version_renames_with_the_files_own_separator(self) -> None:
        self.r.write("changelog.d/fixed/x.md", "- **x.**\n")
        self.ok(self.r.run("assemble", "--version", "1.1.0"))
        text = self.r.read("CHANGELOG.md")
        self.assertRegex(
            text,
            r"## \[Unreleased\]\n\n## \[1\.1\.0\] — \d{4}-\d{2}-\d{2}\n\n"
            r"### Fixed\n\n- \*\*x\.\*\*\n\n## \[1\.0\.0\]",
        )

    def test_version_refuses_an_existing_section(self) -> None:
        self.bad(self.r.run("assemble", "--version", "1.0.0"), "already has")
        self.assertEqual(self.r.read("CHANGELOG.md"), BASE_CHANGELOG)

    def test_version_refuses_a_prerelease(self) -> None:
        self.bad(self.r.run("assemble", "--version", "1.1.0rc1"), "not X.Y.Z")

    def test_check_reports_outstanding_and_mutates_nothing(self) -> None:
        self.ok(self.r.run("assemble", "--check"))
        self.r.write("changelog.d/fixed/x.md", "- **x.**\n")
        self.bad(self.r.run("assemble", "--check"), "changelog.d/fixed/x.md")
        self.assertTrue((self.r.root / "changelog.d/fixed/x.md").exists())
        self.assertEqual(self.r.read("CHANGELOG.md"), BASE_CHANGELOG)

    def test_refuses_to_write_a_malformed_fragment(self) -> None:
        self.r.write("changelog.d/fixed/x.md", "- **x.**\n### Removed\n")
        self.bad(self.r.run("assemble"), "malformed")
        self.assertEqual(self.r.read("CHANGELOG.md"), BASE_CHANGELOG)


class Sections(Base):
    def edit(self, old: str, new: str) -> None:
        text = self.r.read("CHANGELOG.md")
        self.assertIn(old, text)
        self.r.write("CHANGELOG.md", text.replace(old, new, 1))
        self.r.commit()

    def test_unreleased_edit_passes(self) -> None:
        self.edit("## [Unreleased]\n", "## [Unreleased]\n\n- **x.**\n")
        self.ok(self.sections())

    def test_released_body_edit_fails(self) -> None:
        self.edit("- **Shipped fix.** It shipped.\n",
                  "- **Shipped fix.** It shipped.\n- **sneaked in.**\n")
        self.bad(self.sections(), "## [1.0.0]  (changed)")

    def test_released_section_removed_fails(self) -> None:
        self.r.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n")
        self.r.commit()
        self.bad(self.sections(), "## [1.0.0]  (removed)")

    def test_duplicated_heading_fails(self) -> None:
        # The just-makeit#1526 hand-merge: a second, empty copy of a released
        # heading. Keyed by label, the copy that matches history hid it.
        self.edit("## [1.0.0] — 2026-01-01\n",
                  "## [1.0.0] — 2026-01-01\n\n## [1.0.0] — 2026-01-01\n")
        self.bad(self.sections(), "## [1.0.0]  (duplicated)")

    def test_restoring_what_the_tag_shipped_passes(self) -> None:
        # main itself carries a misplaced entry (merged before the gate);
        # taking it back out restores v1.0.0's text and must be allowed.
        self.r.git("checkout", "-q", "main")
        self.r.write("CHANGELOG.md", BASE_CHANGELOG + "- **misplaced.**\n")
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.r.write("CHANGELOG.md", BASE_CHANGELOG)
        self.r.commit()
        self.ok(self.sections())

    def test_release_branch_passes_with_no_name_carve_out(self) -> None:
        self.r.git("checkout", "-q", "-b", "anything-at-all")
        self.r.write("changelog.d/added/x.md", "- **x.**\n")
        self.r.commit()
        self.ok(self.r.run("assemble", "--version", "1.1.0"))
        self.r.commit("release")
        self.ok(self.sections())


if __name__ == "__main__":
    unittest.main()
