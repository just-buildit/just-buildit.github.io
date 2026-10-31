"""Behaviour of scripts/train.py and standard.mk's ``train`` target.

A train lands several ready PRs as one, so a strict ruleset charges one CI
run instead of N. Everything it checks is a way the train could land
something nobody reviewed, or close an issue nobody declared, so each test
here is one of those ways, and each must be REFUSED with nothing published.

The fixture is a throwaway origin (a bare repo) and a clone. Each PR's head
is pushed to ``refs/pull/<n>/head`` on the origin, as GitHub serves it, and
``GH`` points the script at a fake that answers ``pr view``, ``repo view``,
the review-thread query and the closing-issues query from a JSON state file and logs every call, so
a test can assert what was (and was not) created or closed. Stdlib only.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import doctest
import tempfile
import textwrap
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "train.py"
sys.path.insert(0, str(ROOT / "scripts"))
import train  # noqa: E402

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, sys
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    a = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(a) + "\\n")
    if a[:2] == ["repo", "view"]:
        print(json.dumps({"nameWithOwner": "o/r"}))
    elif a[:2] == ["pr", "view"]:
        print(json.dumps(state["prs"][a[2]]))
    elif a[:2] == ["api", "graphql"] and any(
        "closingIssuesReferences" in x for x in a
    ):
        n = next(x[2:] for x in a if x.startswith("n="))
        if n in state.get("closing_fail", []):
            sys.exit("gh: HTTP 502: Bad Gateway")
        if n in state.get("closing_error", []):
            print(json.dumps({"data": {"repository": {"pullRequest": None}},
                              "errors": [{"message": "timeout"}]}))
            sys.exit(0)
        nodes = [
            {"number": int(r.split("#")[1]),
             "repository": {"nameWithOwner": r.split("#")[0] or "o/r"}}
            for r in state.get("closing", {}).get(n, [])
        ]
        print(json.dumps({"data": {"repository": {"pullRequest": {
            "closingIssuesReferences": {
                "totalCount": len(nodes), "nodes": nodes}}}}}))
    elif a[:2] == ["api", "graphql"]:
        n = next(x[2:] for x in a if x.startswith("n="))
        nodes = state.get("threads", {}).get(n, [])
        print(json.dumps({"data": {"repository": {"pullRequest": {
            "reviewThreads": {"nodes": nodes}}}}}))
    elif a[:2] == ["pr", "create"]:
        body = open(a[a.index("--body-file") + 1]).read()
        with open(os.environ["FAKE_GH_LOG"] + ".body", "w") as f:
            f.write(body)
        print("https://github.com/o/r/pull/99")
    elif a[:2] == ["pr", "close"]:
        pass
    else:
        sys.exit("fake gh: unexpected " + " ".join(a))
    """
)


def sh(cwd: pathlib.Path, *args: str) -> str:
    return subprocess.run(
        args, cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.origin = self.tmp / "origin.git"
        sh(
            self.tmp,
            "git",
            "init",
            "--quiet",
            "--bare",
            "-b",
            "main",
            str(self.origin),
        )
        self.work = self.tmp / "work"
        sh(
            self.tmp,
            "git",
            "clone",
            "--quiet",
            str(self.origin),
            str(self.work),
        )
        for k, v in (
            ("user.name", "t"),
            ("user.email", "t@example.com"),
            ("commit.gpgsign", "false"),
        ):
            sh(self.work, "git", "config", k, v)
        (self.work / "shared.txt").write_text("one\ntwo\nthree\n")
        self.commit("base")
        sh(self.work, "git", "push", "--quiet", "origin", "HEAD:main")
        self.state: dict[str, Any] = {
            "prs": {},
            "threads": {},
            "closing": {},
            "closing_fail": [],
        }
        self.log = self.tmp / "gh.log"
        fake = self.tmp / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(0o755)
        self.env = dict(
            os.environ,
            GH=str(fake),
            FAKE_GH_STATE=str(self.tmp / "s.json"),
            FAKE_GH_LOG=str(self.log),
        )

    def commit(self, msg: str) -> str:
        sh(self.work, "git", "add", "-A")
        sh(self.work, "git", "commit", "--quiet", "-m", msg)
        return sh(self.work, "git", "rev-parse", "HEAD")

    def pr(self, n: int, files: dict[str, str], msg: str = "", **meta) -> str:
        """Opens PR #n: one commit off main writing ``files``."""
        sh(
            self.work,
            "git",
            "switch",
            "--quiet",
            "-c",
            f"pr{n}",
            "origin/main",
        )
        for name, text in files.items():
            (self.work / name).write_text(text)
        head = self.commit(msg or f"change {n}\n\nCloses #{100 + n}")
        sh(
            self.work,
            "git",
            "push",
            "--quiet",
            "origin",
            f"HEAD:refs/pull/{n}/head",
        )
        sh(self.work, "git", "switch", "--quiet", "main")
        self.state["prs"][str(n)] = {
            **dict(
                number=n,
                state="OPEN",
                isDraft=False,
                baseRefName="main",
                headRefOid=head,
                title=f"change {n}",
                url=f"https://github.com/o/r/pull/{n}",
            ),
            **meta,
        }
        return head

    def train(self, *args: str) -> subprocess.CompletedProcess:
        (self.tmp / "s.json").write_text(json.dumps(self.state))
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--gate", "true", *args],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(x) for x in self.log.read_text().splitlines()]

    def assertRefused(self, p, why: str) -> None:
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("REFUSED", p.stdout)
        self.assertIn(why, p.stdout)
        # Nothing published, and the clone is back where it started.
        self.assertFalse(
            [
                c
                for c in self.calls()
                if c[:2] in (["pr", "create"], ["pr", "close"])
            ]
        )
        self.assertEqual(
            sh(self.work, "git", "branch", "--show-current"), "main"
        )
        self.assertEqual(
            sh(
                self.work,
                "git",
                "status",
                "--porcelain",
                "--untracked-files=no",
            ),
            "",
        )


class Composes(Fixture):
    def test_dry_run_composes_gates_and_leaves_nothing(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        self.pr(2, {"b.txt": "b\n"})
        p = self.train("--gate", "test -f a.txt && test -f b.txt", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("dry run OK", p.stdout)
        self.assertEqual(
            sh(self.work, "git", "branch", "--list", "train/*"), ""
        )
        self.assertEqual(
            sh(self.work, "git", "branch", "--show-current"), "main"
        )
        self.assertFalse(
            [c for c in self.calls() if c[:2] == ["pr", "create"]]
        )

    def test_push_lands_both_unchanged_and_closes_the_originals(self) -> None:
        h1 = self.pr(1, {"a.txt": "a\n"})
        h2 = self.pr(2, {"b.txt": "b\n"})
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        picked = sh(
            self.work,
            "git",
            "rev-list",
            "--reverse",
            "origin/main..origin/train/1-2",
        ).split()
        self.assertEqual(len(picked), 2)
        for src, dst in zip((h1, h2), picked):
            os.chdir(self.work)
            try:
                self.assertIsNone(train.same_commit(src, dst))
            finally:
                os.chdir(ROOT)
        calls = self.calls()
        self.assertIn(["pr", "close", "1"], [c[:3] for c in calls])
        self.assertIn(["pr", "close", "2"], [c[:3] for c in calls])
        body = pathlib.Path(str(self.log) + ".body").read_text()
        self.assertIn("rebase merge", body)
        self.assertIn("#1", body)
        self.assertIn("#2", body)


class CarriesClosingIssues(Fixture):
    """A constituent is closed unmerged, and a PR closed unmerged closes
    nothing, so the issues each one links must be declared by the train
    itself (just-bashit#160 left three open)."""

    def vendor_gate(self) -> None:
        (self.work / "scripts").mkdir()
        shutil.copy(
            ROOT / "scripts" / "close-keywords.py",
            self.work / "scripts" / "close-keywords.py",
        )
        self.commit("vendor the gate")
        sh(self.work, "git", "push", "--quiet", "origin", "HEAD:main")

    def body(self) -> str:
        return pathlib.Path(str(self.log) + ".body").read_text()

    def test_a_body_only_closing_issue_reaches_the_train(self) -> None:
        # The commit carries no keyword: the PR description did, so only
        # GitHub's closingIssuesReferences knows about #41.
        self.pr(1, {"a.txt": "a\n"}, msg="change 1")
        self.state["closing"]["1"] = ["#41"]
        p = self.train("--push", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("- Closes #41, from #1.\n", self.body())

    def test_an_issue_two_prs_close_is_declared_once(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, msg="change 1")
        self.pr(2, {"b.txt": "b\n"}, msg="change 2")
        self.state["closing"]["1"] = ["#41", "#42"]
        self.state["closing"]["2"] = ["#42"]
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        body = self.body()
        self.assertIn("- Closes #41, from #1.\n", body)
        self.assertIn("- Closes #42, from #1 and #2.\n", body)
        self.assertEqual(body.count("Closes #42"), 1)

    def test_a_cross_repo_issue_keeps_its_owner(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, msg="change 1")
        self.state["closing"]["1"] = ["x/y#7", "#8"]
        p = self.train("--push", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        body = self.body()
        self.assertIn("- Closes x/y#7, from #1.\n", body)
        self.assertIn("- Closes #8, from #1.\n", body)

    def test_none_linked_adds_no_closing_line(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, msg="change 1")
        p = self.train("--push", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        body = self.body()
        self.assertNotIn("Closes", body)
        self.assertIn("None of its PRs links an issue.", body)

    def test_the_landing_text_does_not_promise_rebase_carries_them(
        self,
    ) -> None:
        self.assertNotIn("closing keywords", train.LAND_HOW)
        self.assertIn("closed unmerged", train.LAND_HOW)

    def test_the_keywords_gate_accepts_the_declared_lines(self) -> None:
        # The gate runs on the train's own title and body. Each added line
        # must read as a declaration, cross-repo included, or the gate
        # refuses every train that carries an issue.
        self.vendor_gate()
        self.pr(1, {"a.txt": "a\n"}, msg="change 1")
        self.pr(2, {"b.txt": "b\n"}, msg="change 2")
        self.state["closing"]["1"] = ["#41", "x/y#7"]
        self.state["closing"]["2"] = ["#41"]
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("closing references: 2, each one declared", p.stdout)

    def test_a_train_declares_what_its_commits_close(self) -> None:
        # A commit's mid-sentence keyword is not a declaration on its own,
        # but GitHub's parse links the issue to the PR, and the train's
        # line declares it, so the gate passes and the issue is closed.
        self.vendor_gate()
        self.pr(1, {"a.txt": "a\n"}, msg="change 1\n\nThis fixes #9 here.")
        self.state["closing"]["1"] = ["#9"]
        p = self.train("--push", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


class Refuses(Fixture):
    def test_a_conflicting_pair(self) -> None:
        self.pr(1, {"shared.txt": "one\nTWO\nthree\n"})
        self.pr(2, {"shared.txt": "one\n2\nthree\n"})
        self.assertRefused(self.train("--push", "1", "2"), "#2's commit")

    def test_a_closed_pr(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, state="CLOSED")
        self.assertRefused(self.train("1"), "#1 is closed")

    def test_a_draft(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, isDraft=True)
        self.assertRefused(self.train("1"), "#1 is a draft")

    def test_another_base(self) -> None:
        self.pr(1, {"a.txt": "a\n"}, baseRefName="dev")
        self.assertRefused(self.train("1"), "targets dev")

    def test_an_unresolved_review_thread(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        self.state["threads"]["1"] = [
            {"isResolved": True},
            {"isResolved": False},
        ]
        self.assertRefused(self.train("1"), "1 unresolved review thread")

    def test_a_head_that_moved(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        self.state["prs"]["1"]["headRefOid"] = "0" * 40
        self.assertRefused(self.train("1"), "the PR moved")

    def test_a_merge_commit(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        sh(self.work, "git", "switch", "--quiet", "-c", "side", "origin/main")
        (self.work / "c.txt").write_text("c\n")
        self.commit("side")
        sh(self.work, "git", "switch", "--quiet", "pr1")
        sh(
            self.work,
            "git",
            "merge",
            "--quiet",
            "--no-ff",
            "-m",
            "merge",
            "side",
        )
        head = sh(self.work, "git", "rev-parse", "HEAD")
        sh(
            self.work,
            "git",
            "push",
            "--quiet",
            "-f",
            "origin",
            "HEAD:refs/pull/1/head",
        )
        sh(self.work, "git", "switch", "--quiet", "main")
        self.state["prs"]["1"]["headRefOid"] = head
        self.assertRefused(self.train("1"), "merge commit")

    def test_a_failing_gate_publishes_nothing(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        p = self.train("--push", "--gate", "false", "1")
        self.assertRefused(p, "failed on the combined tree")
        self.assertEqual(
            sh(self.work, "git", "ls-remote", "--heads", "origin", "train/1"),
            "",
        )

    def test_uncommitted_changes(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        (self.work / "shared.txt").write_text("dirty\n")
        p = self.train("1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("uncommitted changes", p.stdout)

    def test_a_pr_listed_twice(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        p = self.train("1", "1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("listed twice", p.stdout)

    def test_an_undeclared_closing_keyword(self) -> None:
        # The vendored gate runs on the train's own title and body; a
        # keyword mid-sentence in a commit is not a declaration.
        (self.work / "scripts").mkdir()
        shutil.copy(
            ROOT / "scripts" / "close-keywords.py",
            self.work / "scripts" / "close-keywords.py",
        )
        self.commit("vendor the gate")
        sh(self.work, "git", "push", "--quiet", "origin", "HEAD:main")
        self.pr(
            1,
            {"a.txt": "a\n"},
            msg="change 1\n\nThis is not what fixes #9 for good.",
        )
        self.assertRefused(
            self.train("--push", "1"), "close-keywords-check refused"
        )


    def test_unreadable_closing_issues(self) -> None:
        # Absent output is not a pass: a train that cannot see what its
        # PRs close must not open and silently leave those issues open.
        self.pr(1, {"a.txt": "a\n"})
        self.pr(2, {"b.txt": "b\n"})
        self.state["closing_fail"] = ["2"]
        self.assertRefused(
            self.train("--push", "1", "2"), "Bad Gateway"
        )

    def test_a_graphql_error_reply(self) -> None:
        # A reply with no list in it, as GraphQL gives alongside "errors",
        # is refused like a failed call, not read as "nothing linked".
        self.pr(1, {"a.txt": "a\n"})
        self.state["closing_error"] = ["1"]
        self.assertRefused(
            self.train("--push", "1"), "cannot read the issues it closes"
        )


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    """train.py's doctests run with the rest."""
    tests.addTests(doctest.DocTestSuite(train))
    return tests


class SameCommit(unittest.TestCase):
    """The patch-id + message comparison is what makes a train land exactly
    what was reviewed; a forged diff or a reworded message must not pass."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        sh(self.tmp, "git", "init", "--quiet", "-b", "main")
        for k, v in (
            ("user.name", "t"),
            ("user.email", "t@example.com"),
            ("commit.gpgsign", "false"),
        ):
            sh(self.tmp, "git", "config", k, v)
        (self.tmp / "f").write_text("base\n")
        self.c("base")
        self.cwd = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, self.cwd)

    def c(self, msg: str) -> str:
        sh(self.tmp, "git", "add", "-A")
        sh(self.tmp, "git", "commit", "--quiet", "-m", msg)
        return sh(self.tmp, "git", "rev-parse", "HEAD")

    def variant(self, text: str, msg: str) -> str:
        sh(self.tmp, "git", "switch", "--quiet", "--detach", "main")
        (self.tmp / "f").write_text(text)
        return self.c(msg)

    def test_identical(self) -> None:
        a = self.variant("x\n", "m\n\nCloses #1")
        b = self.variant("x\n", "m\n\nCloses #1")
        self.assertIsNone(train.same_commit(a, b))

    def test_a_different_diff(self) -> None:
        a = self.variant("x\n", "m")
        b = self.variant("y\n", "m")
        self.assertEqual(train.same_commit(a, b), "its diff differs")

    def test_a_reworded_message(self) -> None:
        a = self.variant("x\n", "m\n\nCloses #1")
        b = self.variant("x\n", "m\n\nCloses #2")
        self.assertEqual(train.same_commit(a, b), "its message differs")


class Target(unittest.TestCase):
    """standard.mk's wiring: PRS and PUSH reach the script."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")
        (self.tmp / "scripts").mkdir()
        (self.tmp / "scripts" / "train.py").write_text(
            "import sys; print('stub', sys.argv[1:])\n"
        )
        (self.tmp / "Makefile").write_text(
            "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\n"
            "CLEAN_PATHS = dist/\ninclude standard.mk\n"
        )

    def make(self, *args: str) -> subprocess.CompletedProcess:
        env = {
            k: v
            for k, v in os.environ.items()
            if k not in ("PRS", "PUSH", "MAKEFLAGS")
        }
        return subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.tmp), *args],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_no_prs_is_usage(self) -> None:
        p = self.make("train")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("usage: make train", p.stdout)

    def test_dry_run_by_default(self) -> None:
        p = self.make("train", "PRS=3 4")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'3', '4'", p.stdout)
        self.assertNotIn("--push", p.stdout)
        self.assertIn("'--gate', 'make lint'", p.stdout)

    def test_push_reaches_the_script(self) -> None:
        p = self.make("train", "PRS=3", "PUSH=1")
        self.assertIn("'--push'", p.stdout)

    def test_train_is_vendored(self) -> None:
        p = self.make("-pn")
        line = next(
            x for x in p.stdout.splitlines() if x.startswith("VENDORED_FILES")
        )
        self.assertIn("scripts/train.py", line)


if __name__ == "__main__":
    unittest.main()
