"""Behaviour of scripts/close-keywords.py: the grammar, then real PRs.

The grammar cases call the module's own functions: every keyword in every
spelling GitHub honours, every reference form, the measured phrases that
closed issues in just-makeit and doppler, and the near misses that must not
count. The pull-request cases build what Actions checks out -- an origin
with a branch and a ``refs/pull/1/merge`` test merge, a clone of that merge
(shallow, as the default checkout is, or full) and the event file -- and run
the script as ``make close-keywords-check`` does. Stdlib only, like the
script: ``python3 -m unittest discover -s tests``.
"""

from __future__ import annotations

import doctest
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "close-keywords.py"

_spec = importlib.util.spec_from_file_location("close_keywords", SCRIPT)
assert _spec is not None and _spec.loader is not None
ck = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ck)

KEYWORDS = (
    "close closes closed fix fixes fixed resolve resolves resolved".split()
)
REPO = "acme/widget"


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    """Run the script's doctests with the rest of the suite."""
    tests.addTests(doctest.DocTestSuite(ck))
    return tests


def found(text: str, title: str = "", where: str = "commit x") -> list:
    return ck.undeclared([(where, text)], title, REPO)


class Grammar(unittest.TestCase):
    def test_every_keyword_spelling_and_separator_is_refused(self) -> None:
        # GitHub: "The keywords can be followed by colons or in uppercase";
        # measured, a line break (even a blank line) between them counts.
        for kw in KEYWORDS:
            for spelt in (kw, kw.capitalize(), kw.upper()):
                for sep in (" ", ": ", ":", " :  ", "\n", ":\n\n"):
                    with self.subTest(kw=spelt, sep=sep):
                        got = found(f"Found and {spelt}{sep}gh-123 today.")
                        phrase = " ".join(f"{spelt}{sep}gh-123".split())
                        self.assertEqual(got, [("commit x, line 1", phrase)])

    def test_every_reference_form_is_refused(self) -> None:
        for ref in (
            "#123",
            "gh-123",
            "GH-123",
            "Gh-123",
            "acme/widget#123",
            "other-org/re.po#123",
            "https://github.com/acme/widget/issues/123",
            "http://github.com/o/r/issues/123#issuecomment-1",
        ):
            with self.subTest(ref=ref):
                got = found(f"It is not fixed: {ref}, sadly.")
                self.assertEqual(len(got), 1, got)

    def test_near_misses_are_not_closing_references(self) -> None:
        for text in (
            "a prefix #12 here",
            "a fix-up #12 here",
            "the fix for #12",
            "fixing #12",
            "it closest #12",
            "fixes 12 things",
            "fixes #12abc",
            "fixes &#123; entity",
            "fixes PR-12",
            "fixed: gh 12",
            "pre_fix #12",
            "see https://github.com/o/r/pull/12 which fixes it",
        ):
            with self.subTest(text=text):
                self.assertEqual(found(text), [])

    def test_the_measured_closures_are_refused(self) -> None:
        # Each of these, in a commit that reached main, CLOSED the issue it
        # names (the issue timelines carry the commit). Undeclared, each is
        # refused, and reported at its own line.
        for text, phrase in (
            (
                "Found measuring the class and filed, not fixed: gh-1960\n"
                "(variable_output drops the param) and gh-1961.",
                "fixed: gh-1960",
            ),
            ("Filed rather than fixed: gh-1516 (composer)", "fixed: gh-1516"),
            ("so this does NOT close #942: a closing", "close #942"),
            ("Closes #723 is NOT claimed -- the backlog", "Closes #723"),
            ("Closes #1310's blocker for the ring", "Closes #1310"),
            ("docs: tier them; #1658 closes\n\n#1838 (five", "closes #1838"),
            ("staggered engines -- the fix\n#1004 proposed", "fix #1004"),
            ("No-issue: the model fix closes #1498", "closes #1498"),
        ):
            with self.subTest(text=text):
                got = found(text)
                self.assertEqual([p for _, p in got], [phrase])

    def test_a_declaration_passes_its_own_mentions(self) -> None:
        prose = "Along the way this fixes gh-7, as measured."
        for title, decl in (
            ("fix: the thing (gh-7)", ""),
            ("fix: the thing (gh-7) (#40)", ""),
            ("feat: x (gh-6, gh-7)", ""),
            ("", "Closes #7"),
            ("", "Closes #7."),
            ("", "Closes: GH-7"),
            ("", "- Fixes gh-7"),
            ("", "* resolves #7, which I filed earlier"),
            ("", "Closes #317. Closes #7."),
            ("", "Closes #1 and fixes #7"),
            ("", "Closes #7 -- what only a tag can exercise is #8"),
            ("", "Closes acme/widget#7"),
            ("", "Closes https://github.com/Acme/Widget/issues/7"),
            ("", "Closes #7\r\nThe body was typed into GitHub's editor."),
        ):
            with self.subTest(title=title, decl=decl):
                sources = [("commit x", prose), ("PR body", decl)]
                self.assertEqual(ck.undeclared(sources, title, REPO), [])

    def test_what_is_not_a_declaration(self) -> None:
        prose = "Along the way this fixes gh-7, as measured."
        for title, decl in (
            ("fix(gh-7): the group does not end the title", ""),
            ("fix: x (gh-7) and then more", ""),
            ("", "We closes #7."),
            ("", "Closes #7 partially"),
            ("", "Closes #7 - partially"),
            ("", "Closes #1 and #7"),
            ("", "Closes other/repo#7"),
            ("", "`Closes #7`"),
        ):
            with self.subTest(title=title, decl=decl):
                sources = [("commit x", prose), ("PR body", decl)]
                got = ck.undeclared(sources, title, REPO)
                self.assertIn(("commit x, line 1", "fixes gh-7"), got)


class PullRequest(unittest.TestCase):
    """The script as CI runs it, over a checked-out test merge."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-q", "-b", "main")
        self.commit("base", "f", "0")
        self.base = self.rev("main")

    def git(self, cwd: pathlib.Path, *args: str) -> str:
        r = subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )
        return r.stdout.strip()

    def rev(self, ref: str) -> str:
        return self.git(self.origin, "rev-parse", ref)

    def commit(self, message: str, path: str = "f", text: str = "") -> str:
        p = self.origin / path
        p.write_text(f"{p.read_text() if p.exists() else ''}{text or message}")
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-q", "-m", message)
        return self.rev("HEAD")

    def branch(self, *messages: str) -> str:
        """Commit ``messages`` on a branch off main; its head."""
        self.git(self.origin, "checkout", "-q", "-b", "topic", "main")
        for i, m in enumerate(messages):
            self.commit(m, f"t{i}")
        head = self.rev("HEAD")
        self.git(self.origin, "checkout", "-q", "main")
        return head

    def run_pr(
        self,
        head: str,
        title: str,
        body: str | None = "",
        *,
        base: str = "",
        shallow: bool = True,
        event_name: str = "pull_request",
        commits: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Check out the test merge as Actions does, and run the script."""
        self.git(self.origin, "checkout", "-q", "--detach", "main")
        self.git(self.origin, "merge", "-q", "--no-ff", "-m", "merge", head)
        self.git(self.origin, "update-ref", "refs/pull/1/merge", "HEAD")
        self.git(self.origin, "checkout", "-q", "main")
        work = self.tmp / "work"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir()
        self.git(work, "init", "-q")
        self.git(work, "remote", "add", "origin", self.origin.as_uri())
        depth = ["--depth=1"] if shallow else []
        ref = "+refs/pull/1/merge:refs/remotes/pull/1/merge"
        self.git(work, "fetch", "-q", "--no-tags", *depth, "origin", ref)
        merge = "refs/remotes/pull/1/merge"
        self.git(work, "checkout", "-q", "--detach", merge)
        n = len(self.git(self.origin, "rev-list", head, "^main").split())
        event = {
            "repository": {"full_name": REPO},
            "pull_request": {
                "title": title,
                "body": body,
                "head": {"sha": head},
                "base": {"sha": base or self.base},
                "commits": n if commits is None else commits,
            },
        }
        path = self.tmp / "event.json"
        path.write_text(json.dumps(event))
        return self.run_script(work, event_name, path)

    def run_script(
        self,
        cwd: pathlib.Path,
        event_name: str,
        path: pathlib.Path | None,
        *args: str,
    ) -> subprocess.CompletedProcess[str]:
        # The suite itself runs in Actions: none of ITS event may leak in.
        env = {k: v for k, v in os.environ.items() if "GITHUB_" not in k}
        if event_name:
            env["GITHUB_EVENT_NAME"] = event_name
        if path is not None:
            env["GITHUB_EVENT_PATH"] = str(path)
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_a_commit_saying_not_fixed_is_refused(self) -> None:
        head = self.branch("fix: a (gh-7)\n\nFiled, not fixed: gh-123.")
        r = self.run_pr(head, "fix: a (gh-7)")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(f'commit {head[:8]}, line 3: "fixed: gh-123"', r.stdout)
        self.assertIn('"filed gh-N"', r.stdout)

    def test_its_own_title_reference_passes(self) -> None:
        head = self.branch("fix: a (gh-7)\n\nThis fixes gh-7 at last.")
        r = self.run_pr(head, "fix: a (gh-7)", None)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("1 commit(s)", r.stdout)
        self.assertIn("closing references: 1, each one declared", r.stdout)

    def test_the_title_and_body_are_read_too(self) -> None:
        head = self.branch("fix: a")
        r = self.run_pr(head, "fix: a, which fixes #3 (gh-7)")
        self.assertIn('PR title, line 1: "fixes #3"', r.stdout)
        r = self.run_pr(head, "fix: a (gh-7)", "Intro.\r\n\r\nnot fixed: #9")
        self.assertIn('PR body, line 3: "fixed: #9"', r.stdout)
        self.assertEqual(r.returncode, 1)
        r = self.run_pr(head, "fix: a", "Closes #9.\r\n\r\nNow fixes #9.")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_a_shallow_checkout_is_read_in_full(self) -> None:
        # The hazard is in the FIRST of three commits, below a depth-1
        # checkout's boundary: read as checked out, the range is cut short
        # and the commit is never seen.
        head = self.branch("one\n\nleft open, fixes gh-5 later", "two", "3")
        r = self.run_pr(head, "feat: x", shallow=True)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('"fixes gh-5"', r.stdout)
        r = self.run_pr(head, "feat: x (gh-5)", shallow=True)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("3 commit(s)", r.stdout)

    def test_a_full_checkout_needs_no_fetch(self) -> None:
        head = self.branch("one\n\nThis fixes: gh-5.", "two")
        r = self.run_pr(head, "feat: x", shallow=False)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn('"fixes: gh-5"', r.stdout)

    def test_main_merged_into_the_branch_is_not_the_prs(self) -> None:
        # main gains a commit that closes #99 sincerely; the branch merges
        # main in; the event's base.sha is the OLD base. The test merge's
        # first parent is the new main, so that commit is not this PR's.
        self.git(self.origin, "checkout", "-q", "-b", "topic", "main")
        self.commit("feat: topic", "t")
        self.git(self.origin, "checkout", "-q", "main")
        self.commit("chore: y\n\nThe model fix closes #99 in passing.", "m")
        self.git(self.origin, "checkout", "-q", "topic")
        self.git(self.origin, "merge", "-q", "--no-ff", "-m", "sync", "main")
        head = self.rev("HEAD")
        self.git(self.origin, "checkout", "-q", "main")
        r = self.run_pr(head, "feat: topic", base=self.base, commits=2)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("2 commit(s)", r.stdout)
        self.assertIn("closing references: none", r.stdout)

    def test_pull_request_target_is_a_pr_run(self) -> None:
        head = self.branch("x\n\nso it resolved: #4")
        r = self.run_pr(head, "x", event_name="pull_request_target")
        self.assertEqual(r.returncode, 1, r.stdout)

    def test_an_unreadable_event_fails_closed(self) -> None:
        work = self.tmp
        r = self.run_script(work, "pull_request", self.tmp / "absent.json")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("cannot read", r.stdout)
        r = self.run_script(work, "pull_request", None)
        self.assertEqual(r.returncode, 1, r.stdout)
        bad = self.tmp / "bad.json"
        bad.write_text(json.dumps({"pull_request": {"title": "x"}}))
        r = self.run_script(work, "pull_request", bad)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("lacks", r.stdout)

    def test_reading_no_commits_is_not_a_pass(self) -> None:
        head = self.branch("x")
        r = self.run_pr(head, "x", base=head, commits=1)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("read no commits", r.stdout)

    def test_any_other_event_is_inert(self) -> None:
        for name in ("push", "merge_group", "schedule"):
            with self.subTest(event=name):
                r = self.run_script(self.origin, name, None)
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertIn(f"a {name} run, inert", r.stdout)

    def test_outside_ci_it_notes_and_never_fails(self) -> None:
        self.branch("x\n\nleft open, fixes gh-5 later", "Closes #6.")
        self.git(self.origin, "checkout", "-q", "topic")
        r = self.run_script(self.origin, "", None, "--base", "main")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("not a pull request run", r.stdout)
        self.assertIn("note: commit", r.stdout)
        self.assertIn('"fixes gh-5"', r.stdout)
        self.assertNotIn("#6", r.stdout.split("\n\n")[1])
        self.git(self.origin, "checkout", "-q", "main")
        r = self.run_script(self.origin, "", None)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("origin/main is not in this clone", r.stdout)


if __name__ == "__main__":
    unittest.main()
