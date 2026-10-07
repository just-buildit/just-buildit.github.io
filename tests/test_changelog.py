"""Behaviour of scripts/changelog.py, driven over real temporary git repos.

Stdlib only (unittest), like the script, so it runs anywhere canonical's CI
does with nothing installed: ``python3 -m unittest discover -s tests``.
Every case builds a ``main`` commit, branches, does what a contributor or a
release would do, and runs the script as the Makefile runs it.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "changelog.py"

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

    def test_a_submodule_moved_while_ignored_needs_a_fragment(self) -> None:
        # just-buildit.github.io#117: `ignore = all` in .gitmodules hid the
        # moved pointer from the diff, so no code had changed.
        def point(sha: str) -> None:
            (self.r.root / "src/sub").mkdir(exist_ok=True)
            entry = f"160000,{sha},src/sub"
            self.r.git("update-index", "--add", "--cacheinfo", entry)

        self.r.git("checkout", "-q", "main")
        self.r.write(
            ".gitmodules",
            '[submodule "sub"]\n\tpath = src/sub\n\turl = ./sub\n'
            "\tignore = all\n",
        )
        point("1" * 40)
        self.r.commit("a submodule")
        self.r.git("checkout", "-q", "feature")
        self.r.git("merge", "-q", "--ff-only", "main")
        point("2" * 40)
        self.r.commit("move it")
        self.bad(self.check(), "no fragment added", "src/sub")

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
        self.ok(self.r.run("assemble", "--version", "1.0.1"))
        self.r.write("src/a.py", "__version__ = '1.0.1'\n")
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
        self.ok(self.r.run("assemble", "--version", "1.0.1"))
        text = self.r.read("CHANGELOG.md")
        self.assertRegex(
            text,
            r"## \[Unreleased\]\n\n## \[1\.0\.1\] — \d{4}-\d{2}-\d{2}\n\n"
            r"### Fixed\n\n- \*\*x\.\*\*\n\n## \[1\.0\.0\]",
        )

    def test_version_refuses_an_existing_section(self) -> None:
        # A release merged and not yet tagged: the number is still the next
        # one by the tags, and the section already there is what refuses it.
        merged = BASE_CHANGELOG.replace(
            "## [1.0.0]", "## [1.0.1] — 2026-01-02\n\n- **y.**\n\n## [1.0.0]"
        )
        self.r.write("CHANGELOG.md", merged)
        self.bad(self.r.run("assemble", "--version", "1.0.1"), "already has")
        self.assertEqual(self.r.read("CHANGELOG.md"), merged)

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


#: A fragment as an author wraps it: a code span split over the line break.
SPLIT = "- **Thing.** Run `jm\n    upgrade` and then\n    carry on.\n"
#: The same fragment after the formatter: exactly what mdformat 1.0.0 wrote
#: for SPLIT (just-makeit gh-1630) -- the indent joined into the span.
JOINED = "- **Thing.** Run `jm   upgrade` and then\n    carry on.\n"
RUN = "a code span holds a run of whitespace"


def _module():
    import importlib.util

    spec = importlib.util.spec_from_file_location("_changelog", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CodeSpans(Base):
    """A spaced code span ships verbatim; the formatter is what makes one."""

    def test_split_span_in_a_fragment_fails(self) -> None:
        self.r.write("changelog.d/fixed/x.md", SPLIT)
        self.r.commit()
        self.bad(self.check(), RUN, "changelog.d/fixed/x.md line 1", "jm\\n")

    def test_formatter_joined_span_in_a_fragment_fails(self) -> None:
        self.r.write("changelog.d/fixed/x.md", JOINED)
        self.r.commit()
        self.bad(self.check(), RUN, "`jm   upgrade`")

    def test_single_spaced_span_passes(self) -> None:
        self.r.write("src/a.py", "x = 2\n")
        self.r.write(
            "changelog.d/fixed/x.md", JOINED.replace("jm   upgrade", "jm upgrade")
        )
        self.r.commit()
        self.ok(self.check())

    def test_deliberate_spacing_in_a_fenced_block_passes(self) -> None:
        # The remedy the refusal names must itself pass.
        self.r.write("src/a.py", "x = 2\n")
        self.r.write(
            "changelog.d/fixed/x.md",
            "- **x.** It prints:\n\n    ```\n    `a   b`    aligned\n    ```\n",
        )
        self.r.commit()
        self.ok(self.check())

    def test_assemble_refuses_a_spaced_span(self) -> None:
        self.r.write("changelog.d/fixed/x.md", JOINED)
        self.bad(self.r.run("assemble"), "refusing", RUN)
        self.assertNotIn("jm   upgrade", self.r.read("CHANGELOG.md"))

    def test_rewording_unreleased_into_a_spaced_span_fails(self) -> None:
        # Rewording is allowed without a fragment, so it is the other way in.
        base = BASE_CHANGELOG.replace(
            "## [Unreleased]\n", "## [Unreleased]\n\n- **Run `jm upgrade`.**\n"
        )
        self.r.git("checkout", "-q", "main")
        self.r.write("CHANGELOG.md", base)
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.r.write("CHANGELOG.md", base.replace("jm upgrade", "jm   upgrade"))
        self.r.commit()
        self.bad(self.check(), RUN, "[Unreleased]")

    def test_a_run_already_in_unreleased_at_the_base_passes(self) -> None:
        # Ratcheted: an adopter re-vendoring does not go red on what it had.
        base = BASE_CHANGELOG.replace(
            "## [Unreleased]\n", "## [Unreleased]\n\n- **Run `jm   upgrade`.**\n"
        )
        self.r.git("checkout", "-q", "main")
        self.r.write("CHANGELOG.md", base)
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.r.write("README.md", "docs\n")
        self.r.commit()
        self.ok(self.check())

    def test_a_run_in_a_released_section_is_not_checked(self) -> None:
        # Released sections are history; changelog-sections-check forbids
        # the edit that would fix one.
        self.r.git("checkout", "-q", "main")
        self.r.write(
            "CHANGELOG.md",
            BASE_CHANGELOG.replace("It shipped.", "Ran `jm   upgrade`."),
        )
        self.r.commit()
        self.r.git("checkout", "-q", "-B", "feature")
        self.r.write("README.md", "docs\n")
        self.r.commit()
        self.ok(self.check())


class SpanPairing(unittest.TestCase):
    """CommonMark pairing, so a run BETWEEN spans is not read as inside one."""

    def runs(self, text: str):
        return _module().span_runs(text)

    def test_a_run_between_spans_is_not_in_one(self) -> None:
        self.assertEqual(self.runs("`a`  and  `b`"), [])

    def test_a_span_closes_only_on_a_run_of_its_own_length(self) -> None:
        spans = [c for _, c in _module().code_spans("``x ` y`` z")]
        self.assertEqual(spans, ["x ` y"])

    def test_an_escaped_tick_opens_nothing(self) -> None:
        self.assertEqual(self.runs("\\`a  b `c`"), [])

    def test_one_space_of_padding_is_legal(self) -> None:
        self.assertEqual(self.runs("` padded `"), [])

    def test_line_is_where_the_span_opens(self) -> None:
        self.assertEqual(self.runs("x\n`a\n    b`"), [(2, "a\n    b")])



class VersionKind(Base):
    """The version rule (just-buildit.github.io#125), over the tag v1.0.0.

    ``version`` is the check-only entry ``release-branch`` calls before it
    branches or bumps; ``assemble --version`` asks the same question before
    it writes. Both are driven, so neither can pass what the other refuses.
    """

    def frag(self, section: str, slug: str = "x") -> None:
        self.r.write(f"changelog.d/{section}/{slug}.md", f"- **{slug}.**\n")

    def version(self, v: str, *extra: str) -> subprocess.CompletedProcess:
        return self.r.run("version", v, *extra)

    def test_an_addition_makes_the_next_minor(self) -> None:
        self.frag("added", "new")
        self.frag("fixed", "bug")
        p = self.version("1.1.0")
        self.ok(p)
        self.assertIn("1.1.0 is the next MINOR over v1.0.0", p.stdout)
        self.ok(self.r.run("assemble", "--version", "1.1.0"))

    def test_a_patch_over_an_addition_is_refused(self) -> None:
        # just-makeit 0.98.4, 2026-10-06: two added/ fragments, and a PATCH
        # proposed and approved.
        self.frag("added", "new")
        line = (
            "1.0.1 is a PATCH over v1.0.0, but changelog.d/added/ holds 1 "
            "fragment (new.md), so this is a MINOR: 1.1.0"
        )
        self.bad(self.version("1.0.1"), line)
        self.bad(self.r.run("assemble", "--version", "1.0.1"), line)
        self.assertEqual(self.r.read("CHANGELOG.md"), BASE_CHANGELOG)
        self.assertTrue((self.r.root / "changelog.d/added/new.md").exists())

    def test_no_addition_makes_the_next_patch(self) -> None:
        # Pre-1.0 a breaking change is said, not counted (release-process).
        self.frag("breaking", "b")
        self.frag("fixed")
        self.frag("docs", "d")
        self.ok(self.version("1.0.1"))
        self.bad(
            self.version("1.1.0"),
            "1.1.0 is a MINOR over v1.0.0, but changelog.d/added/ holds none "
            "(breaking/: 1, fixed/: 1, docs/: 1), so this is a PATCH: 1.0.1",
        )
        self.bad(self.r.run("assemble", "--version", "1.1.0"), "PATCH: 1.0.1")

    def test_with_no_fragment_at_all_it_is_a_patch(self) -> None:
        self.ok(self.version("1.0.1"))
        self.bad(self.version("1.1.0"), "no fragment is outstanding")

    def test_a_skipped_number_is_refused(self) -> None:
        self.frag("fixed")
        self.bad(
            self.version("1.0.2"),
            "1.0.2 skips a number over v1.0.0",
            "so this is a PATCH: 1.0.1",
        )
        self.frag("added", "new")
        for v in ("1.2.0", "1.1.1"):
            with self.subTest(v=v):
                self.bad(
                    self.version(v),
                    f"{v} skips a number over v1.0.0",
                    "so this is a MINOR: 1.1.0",
                )
        self.bad(self.r.run("assemble", "--version", "1.2.0"), "skips")

    def test_a_number_not_above_the_tag_is_refused(self) -> None:
        for v in ("1.0.0", "0.9.9"):
            with self.subTest(v=v):
                self.bad(
                    self.version(v),
                    f"{v} is not above v1.0.0, the last release",
                    "PATCH: 1.0.1",
                )

    def test_a_major_is_a_decision_not_a_fragment(self) -> None:
        self.frag("breaking", "b")
        self.bad(self.version("2.0.0"), "2.0.0 is a MAJOR over v1.0.0")
        self.bad(self.version("2.0.0"), "pass MAJOR=1 (--major)")
        self.bad(self.r.run("assemble", "--version", "2.0.0"), "MAJOR=1")
        self.ok(self.version("2.0.0", "--major"))
        self.bad(self.version("3.0.0", "--major"), "the next MAJOR is 2.0.0")
        # The decision allows a MAJOR and nothing else.
        self.bad(self.version("1.1.0", "--major"), "so this is a PATCH: 1.0.1")
        self.ok(self.r.run("assemble", "--version", "2.0.0", "--major"))

    def test_the_highest_tag_decides_not_the_highest_section(self) -> None:
        # Tagged and never published, so CHANGELOG has no [1.0.1]: its number
        # is burned all the same (just-makeit 0.90.0).
        self.r.git("tag", "v1.0.1")
        self.frag("fixed")
        self.bad(self.version("1.0.1"), "not above v1.0.1", "PATCH: 1.0.2")
        self.ok(self.version("1.0.2"))

    def test_tags_compare_as_numbers_and_only_releases_count(self) -> None:
        # A build tag (just-bashit's v0.1.9-100190b), a pre-release and a tag
        # without the v (just-makeit's 0.9.0) are not releases.
        for t in ("v1.9.0", "v1.10.0", "v9.9.9-abc1234", "v9.0.0rc1", "9.9.9"):
            self.r.git("tag", t)
        self.frag("fixed")
        self.ok(self.version("1.10.1"))

    def test_a_first_release_has_nothing_to_measure_against(self) -> None:
        self.r.git("tag", "-d", "v1.0.0")
        self.frag("fixed")
        p = self.version("0.1.0")
        self.ok(p)
        self.assertIn("first release", p.stdout)
        self.bad(self.version("1.0.0"), "1.0.0 is a MAJOR", "MAJOR=1")
        self.ok(self.version("1.0.0", "--major"))

    def test_an_addition_already_promoted_still_makes_a_minor(self) -> None:
        # A plain `changelog-assemble` promoted it before the release, so no
        # fragment is left to say so.
        self.frag("added", "new")
        self.ok(self.r.run("assemble"))
        self.assertFalse((self.r.root / "changelog.d/added/new.md").exists())
        self.bad(
            self.version("1.0.1"),
            "[Unreleased] already holds 1 ### Added entry",
            "so this is a MINOR: 1.1.0",
        )
        self.ok(self.r.run("assemble", "--version", "1.1.0"))

    def test_rev_reads_that_commit_not_the_working_tree(self) -> None:
        # release-branch asks about origin/main before it has branched: what
        # the checkout holds is not what will be released.
        self.r.git("checkout", "-q", "main")
        self.frag("added", "new")
        self.r.commit()
        self.r.git("checkout", "-q", "feature")
        self.frag("fixed", "local")  # uncommitted, and not on main
        self.ok(self.version("1.0.1"))
        self.bad(
            self.version("1.0.1", "--rev", "main"),
            "changelog.d/added/ holds 1 fragment (new.md)",
            "so this is a MINOR: 1.1.0",
        )
        self.ok(self.version("1.1.0", "--rev", "main"))

    def test_a_rev_that_is_not_there_is_refused(self) -> None:
        self.bad(self.version("1.0.1", "--rev", "origin/main"), "cannot read")

    def test_the_three_near_misses(self) -> None:
        # just-makeit, 2026-09-26 to 10-06: each wrong number was proposed,
        # approved, and caught by hand before its tag.
        self.r.git("tag", "-d", "v1.0.0")
        cases = [
            ("v0.92.0", "fixed", 12, "0.93.0", "0.92.1"),
            ("v0.96.0", "fixed", 3, "0.97.0", "0.96.1"),
            ("v0.98.3", "added", 2, "0.98.4", "0.99.0"),
        ]
        for tag, section, n, wrong, right in cases:
            with self.subTest(tag=tag):
                self.r.git("tag", tag)
                for i in range(n):
                    self.frag(section, f"f{i}")
                self.bad(self.version(wrong), "so this is a ", right)
                self.ok(self.version(right))
                shutil.rmtree(self.r.root / "changelog.d" / section)


#: An adopter's Makefile, with both groups on and a bump that leaves a mark.
RELEASE_MAKEFILE = textwrap.dedent(
    """\
    TEST_CMD = @echo test
    TEST_FAST_CMD = @echo test-fast
    CLEAN_PATHS = dist/
    HAS_RELEASE = 1
    HAS_CHANGELOG = 1
    CHANGELOG_CODE_PATHS = src
    BUMP_VERSION_CMD = printf 'version = "$(VERSION)"\\n' > pyproject.toml
    RELEASE_WATCH_CMD = @echo watch
    VERSION_PROBES = pyproject.toml|cat pyproject.toml
    include standard.mk
    """
)


class ReleaseBranch(unittest.TestCase):
    """``make release-branch`` asks the version rule before it makes anything.

    The adopter's clone is stale on purpose, the way a releaser's is: its
    main is behind origin's, which has since gained an added/ fragment, and
    it holds none of origin's tags (``git fetch origin main`` brings none).
    So the check must read origin/main and fetch the tags itself; reading the
    checkout, or the local tags, accepts the wrong number. And it must run
    before the bump, or its refusal leaves a half-made branch.
    """

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        top = pathlib.Path(tmp.name)
        subprocess.run(
            ["git", "init", "-q", "--bare", "-b", "main", str(top / "o.git")],
            check=True,
        )
        seed = self.clone(top, "seed")
        seed.write("standard.mk", (ROOT / "standard.mk").read_text("utf-8"))
        seed.write("scripts/changelog.py", SCRIPT.read_text("utf-8"))
        seed.write("Makefile", RELEASE_MAKEFILE)
        seed.write(
            "CHANGELOG.md",
            "# Changelog\n\n## [Unreleased]\n\n## [0.98.3] - 2026-10-01\n\n"
            "- **x.**\n",
        )
        seed.write("pyproject.toml", 'version = "0.98.3"\n')
        seed.write("changelog.d/fixed/bug.md", "- **bug.**\n")
        seed.commit("base")
        seed.git("tag", "v0.98.3")
        seed.git("push", "-q", "origin", "HEAD:main", "v0.98.3")
        self.r = self.clone(top, "work")
        self.r.git("tag", "-d", "v0.98.3")
        seed.write("changelog.d/added/new.md", "- **new.**\n")
        seed.commit("an addition")
        seed.git("push", "-q", "origin", "HEAD:main")

    def clone(self, top: pathlib.Path, name: str) -> Repo:
        subprocess.run(
            ["git", "clone", "-q", str(top / "o.git"), str(top / name)],
            check=True,
            capture_output=True,
        )
        r = Repo(top / name)
        r.git("config", "user.email", "t@example.com")
        r.git("config", "user.name", "t")
        r.git("config", "commit.gpgsign", "false")
        r.git("config", "tag.gpgsign", "false")
        return r

    def make(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["make", "--no-print-directory", *args],
            cwd=self.r.root,
            capture_output=True,
            text=True,
            env={**os.environ, **env},
        )

    def assert_untouched(self, version: str) -> None:
        branches = self.r.git("branch", "--list", f"chore/release-{version}")
        self.assertEqual(branches, "", "a refused release left its branch")
        head = self.r.git("rev-parse", "--abbrev-ref", "HEAD")
        self.assertEqual(head, "main\n")
        self.assertEqual(self.r.git("status", "--porcelain"), "")
        self.assertEqual(self.r.read("pyproject.toml"), 'version = "0.98.3"\n')

    def test_a_wrong_kind_is_refused_before_anything_is_made(self) -> None:
        p = self.make("release-branch", "VERSION=0.98.4")
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn(
            "0.98.4 is a PATCH over v0.98.3, but changelog.d/added/ holds 1 "
            "fragment (new.md), so this is a MINOR: 0.99.0",
            p.stdout,
        )
        self.assertNotIn("Bumped to", p.stdout)
        self.assert_untouched("0.98.4")

    def test_a_skipped_number_is_refused_before_anything_is_made(self) -> None:
        p = self.make("release-branch", "VERSION=0.100.0")
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("0.100.0 skips a number over v0.98.3", p.stdout)
        self.assert_untouched("0.100.0")

    def test_the_number_the_fragments_call_for_is_cut(self) -> None:
        p = self.make("release-branch", "VERSION=0.99.0")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("0.99.0 is the next MINOR over v0.98.3", p.stdout)
        head = self.r.git("rev-parse", "--abbrev-ref", "HEAD")
        self.assertEqual(head, "chore/release-0.99.0\n")
        self.assertEqual(self.r.read("pyproject.toml"), 'version = "0.99.0"\n')
        text = self.r.read("CHANGELOG.md")
        self.assertIn("## [0.99.0]", text)
        self.assertIn("### Added\n\n- **new.**", text)
        self.assertFalse((self.r.root / "changelog.d/added/new.md").exists())

    def test_a_major_is_cut_only_by_a_typed_decision(self) -> None:
        # From the environment MAJOR carries no evidence it was meant, the
        # reason a bare VERSION is refused there too.
        p = self.make("release-branch", "VERSION=1.0.0", MAJOR="1")
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("1.0.0 is a MAJOR over v0.98.3", p.stdout)
        self.assert_untouched("1.0.0")
        p = self.make("release-branch", "VERSION=1.0.0", "MAJOR=1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.r.read("pyproject.toml"), 'version = "1.0.0"\n')
        self.assertIn("## [1.0.0]", self.r.read("CHANGELOG.md"))

    def test_the_check_alone_needs_a_version(self) -> None:
        p = self.make("changelog-version-check")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("usage: make changelog-version-check", p.stdout)


if __name__ == "__main__":
    unittest.main()
