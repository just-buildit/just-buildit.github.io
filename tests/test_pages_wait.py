"""Behaviour of scripts/pages-wait.py's ``wait``, offline.

``Re-vendor adopters`` fans out only on ``served=true``, and CI's
``Serving matches the repo`` is red on every :class:`Fail`, so the cases
that matter are the ones a fixed polling window got wrong
(just-buildit.github.io#118): a deploy slower than the window, a build a
newer push cancelled, a build that failed, and a site that serves
something other than the commit.

A fake stands in for :class:`GitHub` -- the Pages run per commit, the
branch head, the paths a range changed, what the site serves -- and a fake
clock advances only when ``wait`` sleeps, so a 14-minute deploy takes no
time. Stdlib only: ``python3 -m unittest discover -s tests``.

``Wiring`` holds the workflows to the script: every job that runs it sits
above its budget, can read the Pages run, and is what the fan-out and CI
passed wait on. A script nobody calls, or one a runner kills first, is
#118 again.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "pages-wait.py"
WORKFLOWS = ROOT / ".github" / "workflows"
RUN_LINE = "run: python3 scripts/pages-wait.py"
_spec = importlib.util.spec_from_file_location("pages_wait", SCRIPT)
assert _spec is not None and _spec.loader is not None
pw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pw)

SHA = "a" * 40  # the commit the workflow ran for
NEWER = "b" * 40  # a later push to the branch
WANT = {"standard.mk": "new-mk", "scripts/x.sh": "x1"}
OLD = {"standard.mk": "old-mk", "scripts/x.sh": "x1"}

BUDGET, INTERVAL, GRACE = pw.BUDGET, pw.INTERVAL, pw.GRACE
RUN = "https://github.com/o/r/actions/runs/1"
DONE = ("completed", "success")


class Fake:
    """Answers that change with the fake clock.

    *runs* maps a commit to ``[(from_t, status, conclusion), ...]``: the
    newest entry whose ``from_t`` has passed is the run's state then (none
    yet is no run). *serve* is ``[(from_t, {path: digest}), ...]`` the same
    way. *unreadable* is how many ``pages_run`` reads fail before one
    answers.
    """

    def __init__(
        self,
        runs: dict,
        serve: list,
        head: str = SHA,
        changed: "set[str] | None" = None,
        unreadable: int = 0,
    ) -> None:
        self.t = 0.0
        self.runs = runs
        self.serve = serve
        self._head = head
        self._changed = changed or set()
        self.unreadable = unreadable
        self.log: "list[str]" = []

    @staticmethod
    def _at(schedule: list, t: float):
        cur = None
        for start, *value in schedule:
            if start <= t:
                cur = value
        return cur

    def pages_run(self, sha: str):
        if self.unreadable:
            self.unreadable -= 1
            raise pw.Unreadable("HTTP 502")
        state = self._at(self.runs.get(sha, []), self.t)
        return None if state is None else (state[0], state[1], RUN)

    def head(self) -> str:
        return self._head

    def changed(self, base: str, head: str) -> "set[str]":
        return self._changed

    def served(self, path: str):
        files = self._at(self.serve, self.t)
        return None if files is None else files[0].get(path)

    def now(self) -> float:
        return self.t

    def sleep(self, s: float) -> None:
        self.t += s


def wait(src: Fake) -> bool:
    return pw.wait(
        src,
        SHA,
        WANT,
        BUDGET,
        INTERVAL,
        GRACE,
        say=src.log.append,
        now=src.now,
        sleep=src.sleep,
    )


def minutes(m: float) -> float:
    return m * 60


class Served(unittest.TestCase):
    def test_a_deploy_slower_than_ten_minutes_is_waited_for(self) -> None:
        # 69410b7: queued, then 13.6 minutes to success. The old window
        # gave up at 10 minutes, about 2.5 before the file was served.
        src = Fake(
            runs={
                SHA: [
                    (0, "queued", ""),
                    (minutes(3), "in_progress", ""),
                    (minutes(13.6), *DONE),
                ]
            },
            serve=[(0, OLD), (minutes(13.6), WANT)],
        )
        self.assertTrue(wait(src))
        self.assertGreater(src.t, minutes(10))

    def test_the_cdn_catching_up_after_the_deploy_is_waited_for(self) -> None:
        src = Fake(
            runs={SHA: [(0, *DONE)]},
            serve=[(0, OLD), (minutes(2), WANT)],
        )
        self.assertTrue(wait(src))

    def test_a_run_that_has_not_appeared_yet_is_waited_for(self) -> None:
        src = Fake(
            runs={SHA: [(minutes(1), *DONE)]},
            serve=[(0, WANT)],
        )
        self.assertTrue(wait(src))
        self.assertGreaterEqual(src.t, minutes(1))

    def test_a_failed_read_is_waited_past(self) -> None:
        src = Fake(
            runs={SHA: [(0, *DONE)]},
            serve=[(0, WANT)],
            unreadable=3,
        )
        self.assertTrue(wait(src))
        self.assertTrue(any("HTTP 502" in m for m in src.log), src.log)


class Superseded(unittest.TestCase):
    def test_a_newer_commit_that_changed_the_files_answers(self) -> None:
        # bd3ba69 and 20b235b: cancelled by a push seconds later, which
        # changed the vendored files and fanned out itself.
        src = Fake(
            runs={
                SHA: [(0, "completed", "cancelled")],
                NEWER: [(0, "in_progress", ""), (minutes(4), *DONE)],
            },
            serve=[(0, {"standard.mk": "newer-mk", "scripts/x.sh": "x1"})],
            head=NEWER,
            changed={"standard.mk"},
        )
        self.assertFalse(wait(src))
        self.assertTrue(any("::notice::" in m for m in src.log), src.log)

    def test_a_newer_commit_that_left_the_files_alone_still_serves(
        self,
    ) -> None:
        # A mirror-bot push cancels the build but starts no re-vendor run
        # of its own: this run must still fan out, once the newer build
        # has published this commit's files.
        src = Fake(
            runs={
                SHA: [(0, "completed", "cancelled")],
                NEWER: [(0, "queued", ""), (minutes(12), *DONE)],
            },
            serve=[(0, OLD), (minutes(12), WANT)],
            head=NEWER,
            changed={"jbs/mirror.sh"},
        )
        self.assertTrue(wait(src))

    def test_a_newer_commit_deployed_before_the_check_is_followed(
        self,
    ) -> None:
        # This build succeeded, but a newer one landed first and serves
        # what the newer commit changed.
        src = Fake(
            runs={
                SHA: [(0, *DONE)],
                NEWER: [(0, *DONE)],
            },
            serve=[(0, {"standard.mk": "newer-mk", "scripts/x.sh": "x1"})],
            head=NEWER,
            changed={"standard.mk"},
        )
        self.assertFalse(wait(src))


class Fails(unittest.TestCase):
    def assertFails(self, src: Fake, *needles: str) -> None:
        with self.assertRaises(pw.Fail) as cm:
            wait(src)
        for n in needles:
            self.assertIn(n, str(cm.exception))

    def test_a_failed_build_fails(self) -> None:
        src = Fake(
            runs={SHA: [(0, "completed", "failure")]}, serve=[(0, OLD)]
        )
        self.assertFails(src, "ended failure", RUN)

    def test_cancelled_with_nothing_newer_fails(self) -> None:
        # Nothing will publish this commit: a manual cancel, not a newer
        # push.
        src = Fake(
            runs={SHA: [(0, "completed", "cancelled")]}, serve=[(0, OLD)]
        )
        self.assertFails(src, "cancelled", "nothing newer")

    def test_serving_something_else_after_the_deploy_fails(self) -> None:
        src = Fake(runs={SHA: [(0, *DONE)]}, serve=[(0, OLD)])
        self.assertFails(src, "serves something else", "standard.mk")

    def test_a_difference_no_later_commit_explains_fails(self) -> None:
        # The newer commit changed scripts/x.sh only; standard.mk still
        # differs, and nothing but a broken publish explains it.
        src = Fake(
            runs={SHA: [(0, "completed", "cancelled")], NEWER: [(0, *DONE)]},
            serve=[(0, {"standard.mk": "junk", "scripts/x.sh": "x2"})],
            head=NEWER,
            changed={"scripts/x.sh"},
        )
        self.assertFails(src, "serves something else", "standard.mk")

    def test_a_build_that_never_completes_fails_within_the_budget(
        self,
    ) -> None:
        src = Fake(runs={SHA: [(0, "in_progress", "")]}, serve=[(0, OLD)])
        self.assertFails(src, "no answer from Pages", "in_progress")
        self.assertLessEqual(src.t, BUDGET + INTERVAL)

    def test_reads_that_never_answer_fail_naming_the_error(self) -> None:
        src = Fake(runs={}, serve=[(0, OLD)], unreadable=10**6)
        self.assertFails(src, "no answer from Pages", "HTTP 502")

#: Stands in for ``gh`` on PATH: prints $FAKE_GH_OUT, $FAKE_GH_ERR to
#: stderr, and exits $FAKE_GH_RC, recording the path it was asked.
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$2" >> "$FAKE_GH_LOG"
printf '%s' "$FAKE_GH_OUT"
[ -z "$FAKE_GH_ERR" ] || printf '%s\\n' "$FAKE_GH_ERR" >&2
exit "$FAKE_GH_RC"
"""


class Reads(unittest.TestCase):
    """:class:`GitHub` over a fake ``gh``: what a read means."""

    def setUp(self) -> None:
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "gh").write_text(FAKE_GH)
        (tmp / "gh").chmod(0o755)
        self.log = tmp / "log"
        env = {
            "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}",
            "FAKE_GH_LOG": str(self.log),
            "FAKE_GH_OUT": "",
            "FAKE_GH_ERR": "",
            "FAKE_GH_RC": "0",
        }
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        self.addCleanup(self._restore, saved)
        self.gh = pw.GitHub("o/r", "main")

    @staticmethod
    def _restore(saved: "dict[str, str | None]") -> None:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def answer(self, out: object = "", err: str = "", rc: int = 0) -> None:
        """What the next ``gh api`` prints, and how it exits."""
        if not isinstance(out, str):
            out = json.dumps(out)
        os.environ["FAKE_GH_OUT"] = out
        os.environ["FAKE_GH_ERR"] = err
        os.environ["FAKE_GH_RC"] = str(rc)

    def test_the_newest_pages_run_for_the_commit_is_read(self) -> None:
        def run(i: int, path: str, conclusion: str) -> dict:
            return {
                "id": i,
                "path": path,
                "status": "completed",
                "conclusion": conclusion,
                "html_url": f"u{i}",
            }

        self.answer(
            {
                "workflow_runs": [
                    run(7, pw.PAGES_RUN, "cancelled"),
                    run(9, ".github/workflows/ci.yml", "failure"),
                    run(8, pw.PAGES_RUN, "success"),
                ]
            }
        )
        self.assertEqual(
            self.gh.pages_run(SHA), ("completed", "success", "u8")
        )
        self.assertIn(f"head_sha={SHA}", self.log.read_text())

    def test_no_pages_run_yet_is_none(self) -> None:
        self.answer({"workflow_runs": []})
        self.assertIsNone(self.gh.pages_run(SHA))

    def test_a_refused_read_fails_at_once(self) -> None:
        self.answer(err="HTTP 403: Resource not accessible", rc=1)
        with self.assertRaises(pw.Fail):
            self.gh.head()

    def test_any_other_failed_read_is_unreadable(self) -> None:
        self.answer(err="HTTP 502: Bad Gateway", rc=1)
        with self.assertRaises(pw.Unreadable):
            self.gh.head()

    def test_an_answer_that_is_not_json_is_unreadable(self) -> None:
        self.answer("<html>")
        with self.assertRaises(pw.Unreadable):
            self.gh.head()


def jobs(workflow: str) -> "dict[str, str]":
    """``{job id: its text}`` for one workflow.

    A job runs from its two-space key to the next one: every deeper line,
    a ``run: |`` block's included, is indented further.
    """
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    body = text[text.index("\njobs:\n") :]
    keys = list(re.finditer(r"^  ([\w-]+):\n", body, re.M))
    return {
        m.group(1): body[m.end() : n.start() if n else len(body)]
        for m, n in zip(keys, keys[1:] + [None])
    }


class Wiring(unittest.TestCase):
    def callers(self) -> "dict[tuple[str, str], str]":
        """Every job, in every workflow here, that runs the script."""
        found = {}
        for wf in sorted(WORKFLOWS.glob("*.yml")):
            for name, text in jobs(wf.name).items():
                if RUN_LINE in text:
                    found[(wf.name, name)] = text
        return found

    def test_both_waits_are_the_script(self) -> None:
        self.assertEqual(
            sorted(self.callers()),
            [("ci.yml", "serving"), ("notify-adopters.yml", "serving")],
        )

    def test_every_caller_outlasts_the_budget_and_the_grace(self) -> None:
        for (wf, name), text in self.callers().items():
            with self.subTest(wf=wf, job=name):
                m = re.search(r"^    timeout-minutes: (\d+)$", text, re.M)
                self.assertIsNotNone(m, "no timeout-minutes")
                assert m is not None
                self.assertGreater(
                    int(m.group(1)) * 60, pw.BUDGET + pw.GRACE
                )

    def test_every_caller_can_read_the_pages_run(self) -> None:
        for (wf, name), text in self.callers().items():
            with self.subTest(wf=wf, job=name):
                self.assertRegex(text, r"(?m)^      actions: read\b")
                self.assertIn("GH_TOKEN: ${{ github.token }}", text)

    def test_the_fan_out_waits_for_served(self) -> None:
        wf = jobs("notify-adopters.yml")
        self.assertIn(
            "served: ${{ steps.wait.outputs.served }}", wf["serving"]
        )
        self.assertRegex(wf["serving"], r"(?m)^        id: wait$")
        self.assertRegex(wf["fan-out"], r"(?m)^    needs: serving$")
        self.assertIn(
            "if: needs.serving.outputs.served == 'true'", wf["fan-out"]
        )

    def test_ci_passed_waits_for_the_serving_check(self) -> None:
        wf = jobs("ci.yml")
        self.assertRegex(wf["ci-passed"], r"(?m)^      - serving$")
        # The step is main-only; the job is not, or CI passed would read
        # its skip as a failure on every PR.
        self.assertNotRegex(wf["serving"], r"(?m)^    if:")


if __name__ == "__main__":
    unittest.main()
