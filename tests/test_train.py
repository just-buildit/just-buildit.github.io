"""Behaviour of scripts/train.py and standard.mk's ``train`` target.

A train lands several ready PRs as one, so a strict ruleset charges one CI
run instead of N. Everything it checks is a way the train could land
something nobody reviewed, or close an issue nobody declared, so each test
here is one of those ways, and each must be REFUSED with nothing published.
``ClosesAfterPublish`` is the exception: once the train PR exists, a
failure is reported as PUBLISHED, never REFUSED.

The fixture is a throwaway origin (a bare repo) and a clone. Each PR's head
is pushed to ``refs/pull/<n>/head`` on the origin, as GitHub serves it, and
``GH`` points the script at a fake that answers ``pr view``, ``repo view``,
the review-thread query, the closing-issues query and ``run list`` /
``run cancel`` from a JSON state file and logs every call, so
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
import contextlib
import io
import tempfile
import textwrap
import unittest
from unittest import mock
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "train.py"
sys.path.insert(0, str(ROOT / "scripts"))
import train  # noqa: E402

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, subprocess, sys
    state = json.load(open(os.environ["FAKE_GH_STATE"]))
    a = sys.argv[1:]
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps(a) + "\\n")

    def origin(*args, check=True):
        return subprocess.run(
            ["git", "-C", os.environ["FAKE_GH_ORIGIN"], *args],
            capture_output=True, text=True, check=check,
        )

    def live(pr):
        # GitHub follows an OPEN PR's branch (and refs/pull/<n>/head);
        # a CLOSED one keeps the head it had when it closed.
        br = pr.get("headRefName")
        if pr["state"] == "OPEN" and br:
            tip = origin("rev-parse", "refs/heads/" + br).stdout.strip()
            pr["headRefOid"] = tip
            origin("update-ref", "refs/pull/%d/head" % pr["number"], tip)
        return pr

    def save():
        json.dump(state, open(os.environ["FAKE_GH_STATE"], "w"))

    if a[:2] == ["repo", "view"]:
        print(json.dumps({"nameWithOwner": "o/r"}))
    elif a[:2] == ["pr", "view"]:
        print(json.dumps(live(state["prs"][a[2]])))
        save()
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
        head = a[a.index("--head") + 1]
        state.setdefault("created", []).append(
            {"number": 99, "url": "https://github.com/o/r/pull/99",
             "state": "OPEN", "headRefName": head,
             "baseRefName": a[a.index("--base") + 1]})
        # GitHub starts the train's own CI the moment its PR opens.
        rid = 9900 + len(state.setdefault("runs", []))
        state["runs"].append(
            {"databaseId": rid, "headBranch": head, "status": "queued",
             "name": "ci", "url": "u/%d" % rid,
             "headSha": origin("rev-parse", "refs/heads/" + head)
             .stdout.strip()})
        save()
        print("https://github.com/o/r/pull/99")
    elif a[:2] == ["pr", "list"]:
        head = a[a.index("--head") + 1]
        print(json.dumps([
            {"number": p["number"], "url": p.get("url", ""),
             "isCrossRepository": p.get("isCrossRepository", False),
             "baseRefName": p["baseRefName"]}
            for p in [*state["prs"].values(), *state.get("created", [])]
            if p.get("headRefName") == head and p["state"] == "OPEN"
        ]))
    elif a[:2] == ["run", "list"]:
        # Without --branch, gh lists every branch's runs.
        br = a[a.index("--branch") + 1] if "--branch" in a else None
        st = a[a.index("--status") + 1]
        if br in state.get("run_list_fail", []):
            sys.exit("gh: HTTP 502: Bad Gateway")
        print(json.dumps([
            r for r in state.get("runs", [])
            if br in (None, r["headBranch"]) and r["status"] == st
        ]))
    elif a[:2] == ["run", "cancel"]:
        if a[2] in state.get("cancel_fail", []):
            sys.exit("gh: HTTP 502: Bad Gateway")
        for r in state.get("runs", []):
            if str(r["databaseId"]) == a[2]:
                r["status"] = "cancelled"
        save()
    elif a[:2] == ["pr", "comment"]:
        if a[2] in state.get("comment_fail", []):
            sys.exit("gh: HTTP 502: Bad Gateway")
    elif a[:2] == ["pr", "close"]:
        # A transient GitHub failure: close_fail counts the tries to fail.
        left = state.get("close_fail", {}).get(a[2], 0)
        if left:
            state["close_fail"][a[2]] = left - 1
            save()
            sys.exit("GraphQL: Something went wrong (closePullRequest)")
        if a[2] in state.get("close_merged", []):
            sys.exit("X Pull request o/r#%s (t) can't be closed because "
                     "it was already merged" % a[2])
        if a[2] in state["prs"]:
            live(state["prs"][a[2]])["state"] = "CLOSED"
            save()
    elif a[:2] == ["pr", "reopen"]:
        pr = state["prs"][a[2]]
        br = "refs/heads/" + pr["headRefName"]
        tip = origin("rev-parse", br)
        # GitHub refuses when the branch was force-pushed while closed.
        if a[2] in state.get("reopen_fail", []) or origin(
            "merge-base", "--is-ancestor", pr["headRefOid"],
            tip.stdout.strip(), check=False,
        ).returncode:
            sys.exit("could not reopen: the head branch was force-pushed")
        pr["state"] = "OPEN"
        save()
        # Someone pushes the moment it reopens: the restore's lease fails.
        racer = state.get("reopen_then_push", {}).get(a[2])
        if racer:
            origin("update-ref", br, racer)
        # Or the remote refuses every push from then on (an outage).
        if a[2] in state.get("reopen_then_reject", []):
            hook = os.path.join(
                os.environ["FAKE_GH_ORIGIN"], "hooks", "pre-receive"
            )
            with open(hook, "w") as f:
                f.write("#!/bin/sh\\necho remote is down >&2\\nexit 1\\n")
            os.chmod(hook, 0o755)
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
            FAKE_GH_ORIGIN=str(self.origin),
            TRAIN_RETRY_DELAY="0",
        )

    def identity(self, **cfg: str) -> None:
        """Sets git identity config (``author_email="t@t"`` ->
        ``author.email``) for the commits made until the test ends. Setting
        a key twice is fine: the cleanup unsets every value it holds."""
        for k, v in cfg.items():
            key = k.replace("_", ".")
            sh(self.work, "git", "config", key, v)
            self.addCleanup(
                subprocess.run,
                ["git", "config", "--unset-all", key],
                cwd=self.work,
                capture_output=True,
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
        state = self.tmp / "s.json"
        state.write_text(json.dumps(self.state))
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--gate", "true", *args],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
        )
        # The fake's view of GitHub (closed, reopened) carries forward.
        self.state = json.loads(state.read_text())
        return p

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
                if c[:2]
                in (["pr", "create"], ["pr", "close"], ["pr", "comment"])
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
        # Each row records the commit it was picked from: a re-cut reads
        # a constituent's head back from its last row.
        self.assertIn(f"| #1 | `{h1}` |", body)
        self.assertIn(f"| #2 | `{h2}` |", body)
        self.assertEqual(train.constituents(body), {1: h1, 2: h2})
        self.assertIn("rebase merge", body)
        self.assertIn("#1", body)
        self.assertIn("#2", body)


class ClosesAfterPublish(Fixture):
    """Once the train PR exists, a failed constituent close is not a
    refusal: the train is published (just-buildit.github.io#192)."""

    def setUp(self) -> None:
        super().setUp()
        self.pr(1, {"a.txt": "a\n"})
        self.pr(2, {"b.txt": "b\n"})

    def closes(self, n: str) -> int:
        return [c[:3] for c in self.calls()].count(["pr", "close", n])

    def test_a_close_that_keeps_failing_says_published(self) -> None:
        self.state["close_fail"] = {"2": 99}
        p = self.train("--push", "1", "2")
        out = p.stdout + p.stderr
        self.assertEqual(p.returncode, train.EXIT_PUBLISHED_PARTIAL, out)
        self.assertEqual(train.EXIT_PUBLISHED_PARTIAL, 3)
        self.assertNotIn("REFUSED", out)
        self.assertIn(
            "train: PUBLISHED -- opened https://github.com/o/r/pull/99, "
            "but #2 did not close after 3 tries",
            p.stdout,
        )
        self.assertIn("train: closed: #1\n", p.stdout)
        self.assertIn(
            "train: still open: #2 -- exited 1: GraphQL: Something went "
            "wrong (closePullRequest)\n",
            p.stdout,
        )
        # #2's comment landed, so only the close is left to finish.
        self.assertIn(
            f"train: finish with:\n  {self.env['GH']} pr close 2\n",
            p.stdout,
        )
        self.assertIn("do not re-run make train PRS='1 2' PUSH=1", p.stdout)
        self.assertIn("gh pr merge https://github.com/o/r/pull/99", p.stdout)
        # The train exists; #1 closed, #2 tried RETRY_TRIES times and open.
        self.assertEqual([c[:2] for c in self.calls()].count(
            ["pr", "create"]), 1)
        self.assertEqual(self.state["prs"]["1"]["state"], "CLOSED")
        self.assertEqual(self.state["prs"]["2"]["state"], "OPEN")
        self.assertEqual(self.closes("2"), train.RETRY_TRIES)
        # A re-run refuses before it publishes anything: #1 is closed.
        self.log.unlink()
        self.assertRefused(self.train("--push", "1", "2"), "#1 is closed")

    def test_a_rerun_after_no_close_finds_the_open_train(self) -> None:
        # Every close failed, so every constituent reads as open; the
        # branch is the open train, which must be finished, not deleted.
        self.state["close_fail"] = {"1": 99, "2": 99}
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("train: closed: none\n", p.stdout)
        self.log.unlink()
        p = self.train("--push", "1", "2")
        self.assertRefused(
            p,
            "branch train/1-2 is already the open train "
            "https://github.com/o/r/pull/99",
        )
        self.assertNotIn("delete it", p.stdout)
        # The same finish command the PUBLISHED path prints.
        url = "https://github.com/o/r/pull/99"
        with mock.patch.dict(os.environ, GH=self.env["GH"]):
            want = [train.finish(n, url, False) for n in (1, 2)]
        self.assertIn(
            "do not re-run. Finish closing its constituents with:\n  "
            + "\n  ".join(want)
            + "\n",
            p.stdout,
        )

    def test_a_transient_close_failure_is_retried(self) -> None:
        self.state["close_fail"] = {"2": 1}
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn(
            "train: opened https://github.com/o/r/pull/99; closed #1, #2",
            p.stdout,
        )
        self.assertNotIn("PUBLISHED", p.stdout)
        self.assertEqual(self.state["prs"]["1"]["state"], "CLOSED")
        self.assertEqual(self.state["prs"]["2"]["state"], "CLOSED")
        self.assertEqual(self.closes("2"), 2)

    def test_a_retried_close_posts_its_comment_once(self) -> None:
        # gh pr close --comment posts before it closes, so a retried
        # close carrying the comment would post it once per try.
        self.state["close_fail"] = {"2": 2}
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        calls = self.calls()
        self.assertEqual(
            [c[2] for c in calls if c[:2] == ["pr", "comment"]], ["1", "2"]
        )
        closes = [c for c in calls if c[:2] == ["pr", "close"]]
        self.assertEqual(len(closes), 4)
        self.assertFalse([c for c in closes if "--comment" in c], closes)

    def test_a_failed_comment_leaves_the_close_to_the_finish(self) -> None:
        self.state["comment_fail"] = ["2"]
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertEqual(self.closes("2"), 0)
        self.assertIn(
            f"  {self.env['GH']} pr close 2 --comment 'Superseded by the "
            "train https://github.com/o/r/pull/99:",
            p.stdout,
        )

    def test_a_constituent_merged_meanwhile_counts_as_done(self) -> None:
        self.state["close_merged"] = ["2"]
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("train: already merged, so not closed: #2", p.stdout)
        self.assertEqual(self.closes("2"), 1)

    def test_a_forks_branch_of_that_name_is_not_the_train(self) -> None:
        # gh pr list --head matches the bare name; a fork's train/1-2 is
        # someone else's, so this is the ordinary branch-exists refusal.
        self.state["prs"]["50"] = dict(
            number=50, state="OPEN", baseRefName="main",
            headRefName="train/1-2", isCrossRepository=True,
            url="https://github.com/o/r/pull/50",
        )
        sh(self.work, "git", "push", "--quiet", "origin",
           "main:refs/heads/train/1-2")
        p = self.train("--push", "1", "2")
        self.assertRefused(p, "already exists on origin at")
        self.assertNotIn("open train", p.stdout)


class CancelsClosedCI(Fixture):
    """A closed constituent's CI gates nothing once the train runs on the
    combined tree, and closing a PR does not cancel it: left running, it
    held the org's macOS runners for 40 minutes while a release queued
    behind it (just-buildit.github.io#200)."""

    def setUp(self) -> None:
        super().setUp()
        self.h = {}
        for n, f in ((1, "a.txt"), (2, "b.txt")):
            self.h[n] = self.pr(n, {f: f"{n}\n"}, headRefName=f"pr{n}")
            sh(self.work, "git", "push", "--quiet", "origin",
               f"pr{n}:refs/heads/pr{n}")

    def run_(self, rid: int, br: str, sha: str, status: str) -> None:
        self.state.setdefault("runs", []).append(
            dict(databaseId=rid, headBranch=br, headSha=sha, status=status,
                 name="ci", url=f"u/{rid}")
        )

    def cancelled(self) -> list[str]:
        return [c[2] for c in self.calls() if c[:2] == ["run", "cancel"]]

    def test_publish_cancels_each_constituents_active_runs(self) -> None:
        self.run_(11, "pr1", self.h[1], "in_progress")
        self.run_(12, "pr1", self.h[1], "queued")
        self.run_(13, "pr1", "0" * 40, "in_progress")  # not the head taken
        self.run_(21, "pr2", self.h[2], "queued")
        self.run_(22, "pr2", self.h[2], "completed")
        # A run on another branch at a constituent's head is not its CI.
        self.run_(31, "main", self.h[1], "in_progress")
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.cancelled(), ["11", "12", "21"])
        self.assertIn("train: cancelled #1's run 11 (ci, u/11)", p.stdout)
        # Each is cancelled only once its PR is closed.
        verbs = [c[:3] for c in self.calls()]
        self.assertLess(
            verbs.index(["pr", "close", "2"]),
            verbs.index(["run", "cancel", "21"]),
        )
        status = {r["databaseId"]: r["status"] for r in self.state["runs"]}
        self.assertEqual(status[13], "in_progress")
        self.assertEqual(status[31], "in_progress")

    def test_the_trains_own_runs_are_never_cancelled(self) -> None:
        self.run_(11, "pr1", self.h[1], "queued")
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        head = sh(self.work, "git", "rev-parse", "origin/train/1-2")
        own = [r for r in self.state["runs"] if r["headBranch"] == "train/1-2"]
        self.assertEqual([r["headSha"] for r in own], [head])
        self.assertEqual(own[0]["status"], "queued")
        self.assertNotIn(str(own[0]["databaseId"]), self.cancelled())
        self.assertFalse(
            [c for c in self.calls() if c[:2] == ["run", "list"]
             and "train/1-2" in c]
        )

    def test_a_failed_cancel_warns_and_still_publishes(self) -> None:
        self.run_(11, "pr1", self.h[1], "queued")
        self.run_(21, "pr2", self.h[2], "queued")
        self.state["cancel_fail"] = ["11"]
        self.state["run_list_fail"] = ["pr2"]
        p = self.train("--push", "1", "2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn("REFUSED", p.stdout)
        self.assertIn(
            "train: warning: cannot cancel #1's run 11 (ci, u/11): "
            "exited 1: gh: HTTP 502: Bad Gateway",
            p.stdout,
        )
        self.assertIn("train: warning: cannot list #2's queued runs on pr2",
                      p.stdout)
        self.assertEqual(self.cancelled(), ["11"] * train.RETRY_TRIES)
        self.assertIn("closed #1, #2", p.stdout)


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

    def test_a_placeholder_author(self) -> None:
        # doppler fdde12e7c: `t <t@t>` rode a train onto main.
        self.identity(author_email="t@t")
        head = self.pr(1, {"a.txt": "a\n"})
        p = self.train("1")
        self.assertRefused(
            p,
            f"#1's commit {head[:9]} is authored by `t <t@t>`, a "
            "placeholder identity",
        )
        self.assertIn("--reset-author", p.stdout)

    def test_a_placeholder_committer(self) -> None:
        self.identity(user_email="t@t", author_email="t@example.com")
        head = self.pr(1, {"a.txt": "a\n"})
        self.assertRefused(
            self.train("1"),
            f"#1's commit {head[:9]} is committed by `t <t@t>`",
        )

    def test_an_email_with_no_at(self) -> None:
        # A dot is not enough: `t.t` has no domain at all.
        self.identity(author_email="t.t")
        head = self.pr(1, {"a.txt": "a\n"})
        self.assertRefused(
            self.train("1"),
            f"#1's commit {head[:9]} is authored by `t <t.t>`",
        )

    def test_bot_and_human_identities_ride(self) -> None:
        self.pr(1, {"a.txt": "a\n"})
        self.identity(
            author_email="41898282+github-actions[bot]"
            "@users.noreply.github.com",
            committer_email="noreply@github.com",
        )
        self.pr(2, {"b.txt": "b\n"})
        self.identity(author_email="noreply@just-buildit.invalid")
        self.pr(3, {"c.txt": "c\n"})
        p = self.train("1", "2", "3")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("dry run OK", p.stdout)

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


class Recuts(Fixture):
    """``--recut T``: a red train's constituents are closed, and GitHub
    refuses to reopen one whose branch was force-pushed while closed
    (doppler#2770). The fake models that refusal and the frozen head."""

    def setUp(self) -> None:
        super().setUp()
        self.heads = {}
        for n, f in ((1, "a.txt"), (2, "b.txt")):
            self.heads[n] = self.pr(n, {f: f"{n}\n"}, headRefName=f"pr{n}")
            sh(self.work, "git", "push", "--quiet", "origin",
               f"pr{n}:refs/heads/pr{n}")
        # One committer date for every pick of the first train. Left to the
        # clock, two picks can straddle a second, and a test that re-picks
        # at the head's date then cannot reproduce the first pick's sha.
        self.env["GIT_COMMITTER_DATE"] = "1800000000 +0000"
        p = self.train("--push", "1", "2")
        del self.env["GIT_COMMITTER_DATE"]
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.state["prs"]["1"]["state"], "CLOSED")
        self.old = sh(self.work, "git", "rev-parse", "origin/train/1-2")
        sh(self.work, "git", "push", "--quiet", "origin",
           f"{self.old}:refs/pull/99/head")
        self.state["prs"]["99"] = dict(
            number=99,
            state="OPEN",
            baseRefName="main",
            headRefName="train/1-2",
            headRefOid=self.old,
            body=pathlib.Path(str(self.log) + ".body").read_text(),
        )
        # prs["99"] now models the train the fake recorded as created.
        del self.state["created"]
        self.log.unlink()

    def fixup(self, n: int) -> str:
        """Force-pushes a reworked commit to PR n's branch, as after a red
        train, while the PR is closed."""
        sh(self.work, "git", "switch", "--quiet", f"pr{n}")
        (self.work / "fix.txt").write_text(f"fix {n}\n")
        sh(self.work, "git", "add", "-A")
        sh(self.work, "git", "commit", "--quiet", "--amend", "-m",
           f"change {n}, fixed")
        sh(self.work, "git", "push", "--quiet", "-f", "origin",
           f"pr{n}:refs/heads/pr{n}")
        sh(self.work, "git", "switch", "--quiet", "main")
        return sh(self.work, "git", "rev-parse", f"pr{n}")

    def refs(self) -> str:
        return sh(self.work, "git", "ls-remote", str(self.origin))

    def verbs(self, verb: str) -> list[str]:
        return [c[2] for c in self.calls() if c[:2] == ["pr", verb]]

    def test_a_dry_run_changes_nothing_on_github(self) -> None:
        before = self.refs()
        p = self.train("--recut", "99")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("would close #99 and reopen #1, #2", p.stdout)
        self.assertIn("make train RECUT=99 PUSH=1", p.stdout)
        self.assertEqual(self.refs(), before)
        for verb in ("close", "reopen", "create"):
            self.assertEqual(self.verbs(verb), [], verb)

    def test_an_unmoved_recut_reopens_and_publishes(self) -> None:
        p = self.train("--recut", "99", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.verbs("reopen"), ["1", "2"])
        self.assertEqual(self.verbs("close"), ["99", "1", "2"])
        self.assertEqual(self.verbs("create"), ["--base"])
        self.assertNotIn("restoring", p.stdout)
        body = pathlib.Path(str(self.log) + ".body").read_text()
        self.assertIn("re-cuts the train #99", body)
        self.assertEqual(train.constituents(body), self.heads)

    def test_a_recut_cancels_the_old_trains_runs_not_its_own(self) -> None:
        # The first train's CI, queued when it opened, is on the branch the
        # re-cut reuses; only its sha tells it from the new train's.
        old = [r for r in self.state["runs"] if r["headSha"] == self.old]
        self.assertEqual([r["status"] for r in old], ["queued"])
        # A later committer date: picks made within the same second as
        # the first train's would reproduce its very commits.
        self.env["GIT_COMMITTER_DATE"] = "1893456000 +0000"
        p = self.train("--recut", "99", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        new = sh(self.work, "git", "rev-parse", "origin/train/1-2")
        self.assertNotEqual(new, self.old)
        status = {r["headSha"]: r["status"] for r in self.state["runs"]}
        self.assertEqual(status[self.old], "cancelled")
        self.assertEqual(status[new], "queued")
        self.assertEqual(
            [c[2] for c in self.calls() if c[:2] == ["run", "cancel"]],
            [str(old[0]["databaseId"])],
        )

    def test_a_recut_to_the_same_head_keeps_its_run(self) -> None:
        # Re-cut onto an unchanged base with the first train's committer
        # date, the picks are its very commits: the run queued for the old
        # head is the new train's own CI, and must not be cancelled.
        self.env["GIT_COMMITTER_DATE"] = sh(
            self.work, "git", "log", "-1", "--format=%cd", "--date=raw",
            self.old,
        )
        p = self.train("--recut", "99", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        new = sh(self.work, "git", "rev-parse", "origin/train/1-2")
        self.assertEqual(new, self.old)
        self.assertEqual(
            [c for c in self.calls() if c[:2] == ["run", "cancel"]], []
        )
        old = [r for r in self.state["runs"] if r["headSha"] == self.old]
        self.assertEqual({r["status"] for r in old}, {"queued"})

    def test_a_moved_head_is_refused(self) -> None:
        new = self.fixup(1)
        before = self.refs()
        p = self.train("--recut", "99", "--push")
        self.assertRefused(p, "moved since the train: #1;")
        self.assertIn(
            f"#1 moved: {self.heads[1][:9]} (change 1) -> "
            f"{new[:9]} (change 1, fixed)",
            p.stdout,
        )
        self.assertEqual(self.verbs("reopen"), [])
        self.assertEqual(self.refs(), before)

    def test_a_named_move_reopens_around_the_force_push(self) -> None:
        new = self.fixup(1)
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("#1 refused to reopen; restoring", p.stdout)
        # Refused once, reopened once with the closed head put back.
        self.assertEqual(self.verbs("reopen"), ["1", "1", "2"])
        self.assertEqual(
            sh(self.work, "git", "ls-remote", "origin", "refs/heads/pr1")
            .split()[0],
            new,
        )
        body = pathlib.Path(str(self.log) + ".body").read_text()
        self.assertEqual(train.constituents(body), {1: new, 2: self.heads[2]})

    def test_a_named_head_that_did_not_move_is_refused(self) -> None:
        self.fixup(1)
        p = self.train("--recut", "99", "--moved", "1,2", "--push")
        self.assertRefused(p, "named in MOVED but not moved: #2")
        self.assertEqual(self.verbs("reopen"), [])

    def interrupt(self, reopened: int) -> None:
        """A re-cut that closed the train and reopened one PR, then
        stopped."""
        self.state["prs"]["99"]["state"] = "CLOSED"
        self.state["prs"][str(reopened)]["state"] = "OPEN"

    def origin_head(self, br: str) -> str:
        return sh(self.work, "git", "ls-remote", "origin",
                  f"refs/heads/{br}").split()[0]

    def test_an_interrupted_recut_reruns(self) -> None:
        self.interrupt(1)
        p = self.train("--recut", "99", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.verbs("reopen"), ["2"])
        self.assertEqual(self.verbs("close"), ["1", "2"])

    def test_an_interrupted_recut_still_checks_a_reopened_head(self) -> None:
        self.interrupt(1)
        new = self.fixup(1)  # pushed while open: GitHub follows it
        p = self.train("--recut", "99", "--push")
        self.assertRefused(p, "moved since the train: #1;")
        self.assertIn(f"{self.heads[1][:9]} (change 1) -> {new[:9]}",
                      p.stdout)
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.verbs("reopen"), ["2"])
        body = pathlib.Path(str(self.log) + ".body").read_text()
        self.assertEqual(train.constituents(body), {1: new, 2: self.heads[2]})

    def test_an_open_pr_a_pre_source_train_never_recorded(self) -> None:
        # doppler#2770: reopened by hand, and the train predates `source`,
        # so nothing says what head was reviewed; only MOVED accepts it.
        body = self.state["prs"]["99"]["body"]
        for h in self.heads.values():
            body = body.replace(f" `{h}` |", "")
        self.assertEqual(train.constituents(body), {1: None, 2: None})
        self.state["prs"]["99"]["body"] = body
        self.state["prs"]["1"]["state"] = "OPEN"
        p = self.train("--recut", "99")
        self.assertRefused(p, "moved since the train: #1;")
        self.assertIn("recorded no head for it", p.stdout)
        p = self.train("--recut", "99", "--moved", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_the_push_back_lease_holds_a_branch_moved_by_the_gate(
        self,
    ) -> None:
        self.fixup(1)
        racer = self.heads[2]
        p = self.train(
            "--recut", "99", "--moved", "1", "--push",
            "--gate", f"git push -q -f origin {racer}:refs/heads/pr1",
        )
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("stale info", p.stdout)
        self.assertEqual(self.origin_head("pr1"), racer)
        self.assertEqual(self.verbs("create"), [])

    def test_a_failed_second_reopen_still_restores_the_head(self) -> None:
        new = self.fixup(1)
        self.state["reopen_fail"] = ["1"]
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("could not reopen", p.stdout)
        self.assertEqual(self.verbs("reopen"), ["1", "1"])
        self.assertEqual(self.origin_head("pr1"), new)
        self.assertEqual(self.verbs("create"), [])

    def test_a_failed_restore_names_the_way_back(self) -> None:
        new = self.fixup(1)
        self.state["reopen_then_push"] = {"1": self.heads[2]}
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("may be left at", p.stdout)
        self.assertIn(
            f"Restore with: git push --force-with-lease=refs/heads/pr1:"
            f"{self.heads[1]} origin {new}:refs/heads/pr1",
            p.stdout,
        )
        # The branch holds the racer's head, which MOVED would accept (it
        # names a PR, not a sha): never tell the reader to push blind.
        self.assertIn("Someone pushed to pr1 after the reopen", p.stdout)
        self.assertIn(
            "with any TRAIN_* overrides you gave: make train RECUT=99 "
            f"MOVED='1'\nAdd PUSH=1 only once its `#1 moved:` line ends at "
            f"the reviewed head {new[:9]}.",
            p.stdout,
        )
        self.assertNotRegex(p.stdout, r"make train [^\n]*PUSH=1")
        # The reviewed head survives the failed run locally.
        self.assertEqual(
            sh(self.work, "git", "rev-parse", "refs/train/closed-1-new"), new
        )

    def test_a_failed_restore_recovers_by_rerunning(self) -> None:
        # The restoring push fails and leaves the branch at the closed
        # head, #1 reopened there and #99 closed: nothing rolled back.
        new = self.fixup(1)
        self.state["reopen_then_reject"] = ["1"]
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn(
            "Then dry-run the same re-cut, with any TRAIN_* overrides you "
            "gave: make train RECUT=99 MOVED='1'\n",
            p.stdout,
        )
        self.assertNotIn("Someone pushed", p.stdout)
        self.assertEqual(self.origin_head("pr1"), self.heads[1])
        self.assertEqual(self.state["prs"]["1"]["state"], "OPEN")
        self.assertEqual(self.state["prs"]["99"]["state"], "CLOSED")
        (self.origin / "hooks" / "pre-receive").unlink()
        # Re-run before the restore: refused, failing closed.
        self.log.unlink()
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertRefused(p, "named in MOVED but not moved: #1")
        # The printed restore, then the dry run: it shows the move ending
        # at the reviewed head, and only then the push lands it and
        # reopens #2, which the failed run never reached.
        sh(self.work, "git", "push", "--quiet",
           f"--force-with-lease=refs/heads/pr1:{self.heads[1]}", "origin",
           f"{new}:refs/heads/pr1")
        p = self.train("--recut", "99", "--moved", "1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn(f"#1 moved: {self.heads[1][:9]} (change 1) -> "
                      f"{new[:9]} (change 1, fixed)", p.stdout)
        p = self.train("--recut", "99", "--moved", "1", "--push")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.verbs("reopen"), ["2"])
        self.assertEqual(self.verbs("create"), ["--base"])
        body = pathlib.Path(str(self.log) + ".body").read_text()
        self.assertEqual(train.constituents(body), {1: new, 2: self.heads[2]})

    def test_a_placeholder_author_on_a_moved_head(self) -> None:
        # A re-cut composes through the same per-PR read as a train.
        self.identity(author_email="t@t")
        self.fixup(1)  # --amend keeps the author, so reset it too
        sh(self.work, "git", "switch", "--quiet", "pr1")
        sh(self.work, "git", "commit", "--quiet", "--amend", "--no-edit",
           "--reset-author")
        sh(self.work, "git", "switch", "--quiet", "main")
        new = sh(self.work, "git", "rev-parse", "pr1")
        sh(self.work, "git", "push", "--quiet", "-f", "origin",
           "pr1:refs/heads/pr1")
        p = self.train("--recut", "99", "--moved", "1")
        self.assertRefused(
            p, f"#1's commit {new[:9]} is authored by `t <t@t>`"
        )

    def test_a_reused_branch_that_moved_is_refused(self) -> None:
        # A run that closed the train, pushed the new one's branch and
        # stopped before its PR: GitHub holds the closed train's head.
        self.state["prs"]["99"]["state"] = "CLOSED"
        other = self.heads[1]
        sh(self.work, "git", "push", "--quiet", "-f", "origin",
           f"{other}:refs/heads/train/1-2")
        p = self.train("--recut", "99", "--push")
        self.assertRefused(p, "already exists on origin at")
        self.assertIn(
            f"git push --force-with-lease=refs/heads/train/1-2:{other} "
            "origin :refs/heads/train/1-2",
            p.stdout,
        )

    def test_a_stale_local_train_branch_is_not_another_train(self) -> None:
        # A fix was pushed onto the red train from another clone; this
        # clone's train/1-2 still holds the original head. #99 is the
        # train being re-cut, not an open train left to finish.
        sh(self.work, "git", "switch", "--quiet", "-c", "tmpfix", self.old)
        (self.work / "fix.txt").write_text("x\n")
        new = self.commit("fix on train")
        for ref in ("refs/heads/train/1-2", "refs/pull/99/head"):
            sh(self.work, "git", "push", "--quiet", "-f", "origin",
               f"{new}:{ref}")
        sh(self.work, "git", "switch", "--quiet", "main")
        sh(self.work, "git", "branch", "-D", "tmpfix")
        self.state["prs"]["99"]["headRefOid"] = new
        p = self.train("--recut", "99", "--push")
        self.assertRefused(p, "branch train/1-2 already exists locally")
        self.assertNotIn("open train", p.stdout)

    def test_a_dry_run_keeps_a_local_train_branch(self) -> None:
        self.assertEqual(
            sh(self.work, "git", "rev-parse", "train/1-2"), self.old
        )
        p = self.train("--recut", "99")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(
            sh(self.work, "git", "rev-parse", "train/1-2"), self.old
        )
        self.assertEqual(
            sh(self.work, "git", "branch", "--list", "dry-run/*"), ""
        )

    def test_a_merged_train(self) -> None:
        self.state["prs"]["99"]["state"] = "MERGED"
        self.assertRefused(self.train("--recut", "99"), "is merged")

    def test_prs_and_recut_together(self) -> None:
        p = self.train("--recut", "99", "1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not both or neither", p.stdout)


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    """train.py's doctests run with the rest."""
    tests.addTests(doctest.DocTestSuite(train))
    return tests


class Retires(Fixture):
    """``--retire T``: once train T merges, each constituent's branch still
    at the head T's table recorded is deleted, and one that moved is kept
    and named (just-buildit.github.io#219). GitHub's delete-on-merge fires
    only for the train itself, so without this they pile up forever."""

    def setUp(self) -> None:
        super().setUp()
        self.heads = {}
        for n, f in ((1, "a.txt"), (2, "b.txt"), (3, "c.txt")):
            self.heads[n] = self.pr(n, {f: f"{n}\n"}, headRefName=f"pr{n}")
            sh(self.work, "git", "push", "--quiet", "origin",
               f"pr{n}:refs/heads/pr{n}")
        p = self.train("--push", "1", "2", "3")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        # It merges, and GitHub deletes the train's own branch.
        sh(self.work, "git", "push", "--quiet", "origin",
           ":refs/heads/train/1-2-3")
        self.state["prs"]["99"] = dict(
            number=99,
            state="MERGED",
            body=pathlib.Path(str(self.log) + ".body").read_text(),
        )
        del self.state["created"]
        self.log.unlink()

    def branches(self) -> dict[str, str]:
        out = sh(self.work, "git", "ls-remote", "--heads", str(self.origin))
        return {
            ref.removeprefix("refs/heads/"): sha
            for sha, ref in (x.split() for x in out.splitlines())
        }

    def move(self, n: int) -> str:
        """Pushes a new commit onto PR n's branch, after the train took
        it."""
        sh(self.work, "git", "switch", "--quiet", f"pr{n}")
        (self.work / "later.txt").write_text(f"later {n}\n")
        tip = self.commit(f"later {n}")
        sh(self.work, "git", "push", "--quiet", "origin",
           f"pr{n}:refs/heads/pr{n}")
        sh(self.work, "git", "switch", "--quiet", "main")
        return tip

    def test_heads_that_match_are_deleted_and_a_moved_one_is_kept(
        self,
    ) -> None:
        tip = self.move(3)
        summary = self.tmp / "summary.md"
        self.env["GITHUB_STEP_SUMMARY"] = str(summary)
        p = self.train("--retire", "99")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        left = self.branches()
        self.assertNotIn("pr1", left)
        self.assertNotIn("pr2", left)
        self.assertEqual(left.get("pr3"), tip)
        self.assertIn("main", left)
        said = (
            f"kept: #3: pr3 moved after the train took it: "
            f"{self.heads[3][:9]} -> {tip[:9]}"
        )
        self.assertIn(said, p.stdout)
        self.assertIn("deleted: #1: pr1 deleted at", p.stdout)
        self.assertIn("**kept** #3: pr3 moved", summary.read_text())

    def test_a_rerun_finds_them_gone(self) -> None:
        self.assertEqual(self.train("--retire", "99").returncode, 0)
        p = self.train("--retire", "99")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("gone: #1: pr1 is already gone", p.stdout)
        self.assertEqual(set(self.branches()), {"main"})

    def test_a_pr_with_no_table_is_a_no_op(self) -> None:
        self.state["prs"]["50"] = dict(
            number=50, state="MERGED", body="Closes #7\n\n| a | #1 |x"
        )
        before = self.branches()
        p = self.train("--retire", "50")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("#50 is not a train; nothing to retire", p.stdout)
        self.assertEqual(self.branches(), before)
        # Not a single constituent was even looked up.
        self.assertEqual(
            [c[:3] for c in self.calls()], [["pr", "view", "50"]]
        )

    def test_an_unmerged_train_keeps_every_branch(self) -> None:
        # A red train is re-cut from its constituents' branches.
        self.state["prs"]["99"]["state"] = "CLOSED"
        before = self.branches()
        p = self.train("--retire", "99")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("#99 is closed, not merged", p.stdout)
        self.assertEqual(self.branches(), before)

    def test_a_fork_an_open_pr_and_no_record_are_kept(self) -> None:
        self.state["prs"]["1"]["isCrossRepository"] = True
        self.state["prs"]["2"]["state"] = "OPEN"
        body = self.state["prs"]["99"]["body"]
        self.state["prs"]["99"]["body"] = body.replace(
            f" `{self.heads[3]}` |", ""
        )
        p = self.train("--retire", "99")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(set(self.branches()), {"main", "pr1", "pr2", "pr3"})
        self.assertIn("#1: its branch pr1 is in a fork", p.stdout)
        self.assertIn("#2: pr2 -- the PR is open again", p.stdout)
        self.assertIn("#3: pr3 -- the train recorded no head", p.stdout)

    def test_a_push_racing_the_delete_keeps_the_branch(self) -> None:
        # Between the ls-remote and the delete, someone pushes: the lease
        # is what keeps it, not the earlier read.
        tip = self.move(2)
        real = train.git

        def stale(*args: str, check: bool = True) -> str:
            out = real(*args, check=check)
            if args[:2] == ("ls-remote", "--heads") and "pr2" in args[-1]:
                return out.replace(tip, self.heads[2])
            return out

        (self.tmp / "s.json").write_text(json.dumps(self.state))
        out = io.StringIO()
        cwd = os.getcwd()
        os.chdir(self.work)
        try:
            with mock.patch.dict(os.environ, self.env), mock.patch.object(
                train, "git", stale
            ), contextlib.redirect_stdout(out):
                rc = train.main(["--retire", "99"])
        finally:
            os.chdir(cwd)
        self.assertEqual(rc, 0, out.getvalue())
        self.assertIn("#2: pr2 moved while it was being retired",
                      out.getvalue())
        self.assertEqual(self.branches().get("pr2"), tip)
        self.assertNotIn("pr1", self.branches())

    def test_retire_takes_no_other_operation(self) -> None:
        p = self.train("--retire", "99", "1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--retire T takes no other operation", p.stdout)
        self.assertEqual(len(self.branches()), 4)


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
            if k not in ("PRS", "PUSH", "RECUT", "MOVED", "MAKEFLAGS")
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

    def _flags(self, flags: str) -> None:
        (self.tmp / "Makefile").write_text(
            flags + "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\n"
            "PYEXT_CMD = @echo p\nCLEAN_PATHS = dist/\ninclude standard.mk\n"
        )

    def test_an_extension_repo_rebuilds_it_before_the_lint(self) -> None:
        # The train lints in the checkout it switched, whose extension was
        # built from whatever that checkout last held; a lint importing it
        # judges the old code (doppler#2749). So with pyext, it goes first.
        self._flags("HAS_C = 1\nHAS_PYTHON = 1\n")
        p = self.make("train", "PRS=3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'--gate', 'make pyext && make lint'", p.stdout)

    def test_python_without_c_has_no_extension_to_rebuild(self) -> None:
        self._flags("HAS_PYTHON = 1\n")
        p = self.make("train", "PRS=3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'--gate', 'make lint'", p.stdout)

    def test_c_without_python_has_no_extension_to_rebuild(self) -> None:
        self._flags("HAS_C = 1\n")
        p = self.make("train", "PRS=3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'--gate', 'make lint'", p.stdout)

    def test_an_explicit_gate_still_wins(self) -> None:
        self._flags("HAS_C = 1\nHAS_PYTHON = 1\n")
        p = self.make("train", "PRS=3", "TRAIN_GATE=true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'--gate', 'true'", p.stdout)

    def test_recut_and_moved_reach_the_script(self) -> None:
        p = self.make("train", "RECUT=9", "MOVED=3 4", "PUSH=1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("'--recut', '9', '--moved', '3 4', '--push'",
                      p.stdout)

    def test_moved_cannot_swallow_prs(self) -> None:
        # `--moved` once took every token after it, so MOVED=5 PRS=6 read
        # as MOVED='5 6' and printed a PUSH=1 line accepting #6 unreviewed.
        shutil.copy(SCRIPT, self.tmp / "scripts" / "train.py")
        p = self.make("train", "RECUT=10", "MOVED=5", "PRS=6")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not both or neither", p.stdout)
        self.assertNotIn("PUSH=1", p.stdout)

    def test_push_reaches_the_script(self) -> None:
        p = self.make("train", "PRS=3", "PUSH=1")
        self.assertIn("'--push'", p.stdout)

    def test_retire_reaches_the_script(self) -> None:
        p = self.make("train-retire", "TRAIN=12")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("['--retire', '12']", p.stdout)

    def test_retire_without_a_train_is_usage(self) -> None:
        p = self.make("train-retire")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("usage: make train-retire TRAIN=", p.stdout)

    def test_train_is_vendored(self) -> None:
        p = self.make("-pn")
        line = next(
            x for x in p.stdout.splitlines() if x.startswith("VENDORED_FILES")
        )
        self.assertIn("scripts/train.py", line)
        self.assertIn(".github/workflows/train-retire.yml", line)
        # `.github/` is served from `github/`: the source must exist there.
        self.assertTrue(WORKFLOW.exists())


WORKFLOW = ROOT / "github" / "workflows" / "train-retire.yml"


class RetireWorkflow(unittest.TestCase):
    """The vendored workflow: on a merged PR from this repository only,
    with the token it needs, calling the target -- and the workflow gates
    every adopter's lint runs over it pass, and go red when it breaks."""

    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")
        (self.tmp / "scripts").mkdir()
        shutil.copy(ROOT / "scripts" / "ci-runner.py", self.tmp / "scripts")
        (self.tmp / ".github" / "workflows").mkdir(parents=True)
        (self.tmp / "Makefile").write_text(
            "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\n"
            "CLEAN_PATHS = dist/\ninclude standard.mk\n"
        )

    def gates(self, text: str) -> subprocess.CompletedProcess:
        (self.tmp / ".github" / "workflows" / "train-retire.yml").write_text(
            text
        )
        return subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.tmp),
             "workflow-timeout-check", "workflow-dispatch-check",
             "self-hosted-check", "help-check"],
            capture_output=True, text=True,
            env={k: v for k, v in os.environ.items() if k != "MAKEFLAGS"},
        )

    def test_it_runs_on_a_merged_pr_of_this_repository_only(self) -> None:
        self.assertIn("types: [closed]", self.text)
        self.assertIn("github.event.pull_request.merged == true", self.text)
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == "
            "github.repository",
            self.text,
        )
        self.assertIn("permissions: {}", self.text)
        self.assertIn("contents: write", self.text)

    def test_it_calls_the_target_with_the_number_from_env(self) -> None:
        self.assertIn('run: make -s train-retire TRAIN="$TRAIN"', self.text)
        self.assertIn(
            "TRAIN: ${{ github.event.pull_request.number || inputs.train }}",
            self.text,
        )

    def test_the_workflow_gates_pass(self) -> None:
        p = self.gates(self.text)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_no_timeout_is_red(self) -> None:
        p = self.gates(self.text.replace("    timeout-minutes: 5\n", ""))
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("train-retire.yml: retire", p.stdout + p.stderr)

    def test_no_dispatch_is_red(self) -> None:
        cut = self.text.index("  workflow_dispatch:")
        end = self.text.index("# Every `run:`")
        p = self.gates(self.text[:cut] + "\n" + self.text[end:])
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("train-retire.yml", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
