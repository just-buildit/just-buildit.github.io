"""Behaviour of scripts/verify-ci.py, offline (just-buildit.github.io#226).

One script answers "did main's CI certify this commit?" for both askers: a
release workflow's verify job (``make release-verify-ci``) and
``release-watch.sh`` when that job failed. Its rule is to wait while the
SHA's CI run is ALIVE -- a fixed window counted queue time and failed
just-makeit v0.127.1 and v0.128.0 on a CI merely queued -- and to give a
verdict only on an answer: a read GitHub did not answer is retried, then
waited past, never read as "finished" (the watch's own copy of the lookup
did exactly that, and spent the recovery).

A fake stands in for the REST API, routed by path the way GitHub routes
it, and a fake clock advances only when the script sleeps, so a four-hour
queue takes no time. ``Wiring`` drives a fixture adopter's make to hold
standard.mk to the script. Stdlib only.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse
from typing import Any, Optional

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "verify-ci.py"
_spec = importlib.util.spec_from_file_location("verify_ci", SCRIPT)
assert _spec is not None and _spec.loader is not None
vc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vc)

REPO = "o/r"
SHA = "abc123"
URL = "https://github.com/o/r/actions/runs/7"
# A run that outlasts gh-1327's 60-min window many times over, in polls.
LONG = 2000

# Measured 2026-11-11 over just-makeit's 100 most recent main-push runs of
# ci.yml: `created_at` is 3-5 s after the head commit. The appear window
# must clear that by far more than a webhook delay.
OBSERVED_MAX_APPEAR_S = 5
APPEAR_FLOOR_S = 300


def run(
    status: str, conclusion: Optional[str] = None, attempt: int = 1
) -> dict[str, Any]:
    """One entry of GET .../actions/workflows/{id}/runs; each attempt has
    its own check suite, ``attempt`` * 100."""
    return {
        "id": 7,
        "run_attempt": attempt,
        "head_sha": SHA,
        "event": "push",
        "status": status,
        "conclusion": conclusion,
        "check_suite_id": attempt * 100,
        "html_url": URL,
    }


def check(conclusion: str, name: str = "CI passed") -> dict[str, Any]:
    return {"name": name, "status": "completed", "conclusion": conclusion}


class FakeApi:
    """The two endpoints verify-ci reads, from scripted replies.

    ``states`` is the CI lookup's reply on each successive poll -- a run
    dict, None (no run for the SHA yet), or an exception instance to
    raise -- the last one repeated. ``checks`` maps a check-suite id to its
    check-runs, filtered by ``check_name`` as GitHub does. Past ``limit``
    polls this raises: a loop that never ends is a failure, not a hang.
    """

    def __init__(
        self,
        states: list[Any],
        checks: Optional[dict[int, list[dict[str, Any]]]] = None,
        limit: int = 50 * LONG,
    ) -> None:
        self.states = states
        self.checks = checks or {}
        self.limit = limit
        self.polls = 0
        self.paths: list[str] = []

    def __call__(self, path: str) -> Any:
        self.paths.append(path)
        base, _, query = path.partition("?")
        args = dict(q.split("=", 1) for q in query.split("&"))
        if "/check-suites/" in base:
            suite = int(base.split("/")[-2])
            name = urllib.parse.unquote(args["check_name"])
            found = [
                c for c in self.checks.get(suite, []) if c["name"] == name
            ]
            return {"total_count": len(found), "check_runs": found}
        assert base == f"repos/{REPO}/actions/workflows/ci.yml/runs", base
        assert args == {
            "head_sha": SHA,
            "branch": "main",
            "event": "push",
            "per_page": "10",
        }, args
        state = self.states[min(self.polls, len(self.states) - 1)]
        self.polls += 1
        if self.polls > self.limit:
            raise AssertionError("verify() polled past any sane bound")
        if isinstance(state, Exception):
            raise state
        runs = [state] if state else []
        return {"total_count": len(runs), "workflow_runs": runs}


GREEN = {100: [check("success")]}


class Clock:
    def __init__(self) -> None:
        self.t = 0.0
        self.sleeps: list[float] = []

    def now(self) -> float:
        return self.t

    def sleep(self, s: float) -> None:
        self.sleeps.append(s)
        self.t += s


def verify(api: FakeApi, **kw: Any) -> tuple[Any, list[str], Clock]:
    said: list[str] = []
    clock = Clock()
    v = vc.verify(
        REPO,
        SHA,
        api=api,
        say=said.append,
        now=clock.now,
        sleep=clock.sleep,
        **kw,
    )
    return v, said, clock


class ALiveRunIsWaitedFor(unittest.TestCase):
    def test_a_long_queue_then_a_long_run_is_waited_out(self) -> None:
        """The v0.128.0 shape: queued with no jobs for longer than the old
        60-min window, then running longer again, then green."""
        api = FakeApi(
            [run("pending")] * LONG
            + [run("queued")] * LONG
            + [run("in_progress")] * LONG
            + [run("completed", "success")],
            GREEN,
        )
        v, said, _ = verify(api)
        self.assertEqual(v.verdict, "green", said[-1:])
        self.assertEqual(api.polls, 3 * LONG + 1)

    def test_every_live_status_keeps_waiting(self) -> None:
        for status in sorted(vc.LIVE_STATUSES):
            with self.subTest(status=status):
                api = FakeApi(
                    [run(status)] * LONG + [run("completed", "success")],
                    GREEN,
                )
                self.assertEqual(verify(api)[0].verdict, "green")

    def test_a_waiting_line_names_the_run_and_the_only_cap(self) -> None:
        api = FakeApi([run("queued"), run("completed", "success")], GREEN)
        _, said, _ = verify(api)
        self.assertIn(URL, said[0])
        self.assertIn("queued", said[0])
        # A job GitHub ends at its timeout must read as that: the last line
        # before the cancel says the timeout is the cap.
        self.assertIn("timeout-minutes is the only cap", said[0])

    def test_a_given_cap_stops_a_live_run_as_alive(self) -> None:
        v, said, clock = verify(FakeApi([run("queued")]), max_minutes=75)
        self.assertEqual(v.verdict, "alive")
        self.assertEqual(sum(clock.sleeps), 75 * 60)
        self.assertEqual(v.run_url, URL)
        self.assertIn("the cap is 75 min", said[0])


class OnlyAnAbsentRunHasAWindow(unittest.TestCase):
    def test_no_run_ever_is_no_run_after_the_appear_window(self) -> None:
        api = FakeApi([None])
        v, _, clock = verify(api)
        self.assertEqual(v.verdict, "no-run")
        self.assertEqual(api.polls, vc.APPEAR // vc.INTERVAL + 1)
        self.assertEqual(sum(clock.sleeps), vc.APPEAR)
        self.assertIn("appeared", v.message)

    def test_a_run_appearing_inside_the_window_is_followed(self) -> None:
        api = FakeApi(
            [None] * (vc.APPEAR // vc.INTERVAL)
            + [run("queued")] * LONG
            + [run("completed", "success")],
            GREEN,
        )
        self.assertEqual(verify(api)[0].verdict, "green")

    def test_the_appear_window_clears_its_measurement(self) -> None:
        self.assertGreaterEqual(vc.APPEAR, APPEAR_FLOOR_S)
        self.assertGreater(APPEAR_FLOOR_S, OBSERVED_MAX_APPEAR_S)


class ACompletedRunIsJudgedByItsOwnCheck(unittest.TestCase):
    def test_green(self) -> None:
        v, _, _ = verify(FakeApi([run("completed", "success")], GREEN))
        self.assertEqual((v.verdict, v.run_id, v.run_url), ("green", "7", URL))

    def test_red_names_the_run_and_conclusion(self) -> None:
        v, _, _ = verify(
            FakeApi([run("completed", "failure")], {100: [check("failure")]})
        )
        self.assertEqual(v.verdict, "red")
        self.assertIn(URL, v.message)
        self.assertIn("'failure'", v.message)

    def test_a_run_that_never_reached_the_check_is_no_check(self) -> None:
        """A pending run superseded by a newer push to main is cancelled
        before `CI passed` exists (#226 finding 5)."""
        v, _, _ = verify(FakeApi([run("completed", "cancelled")]))
        self.assertEqual(v.verdict, "no-check")
        self.assertIn(URL, v.message)
        self.assertIn("'cancelled'", v.message)

    def test_the_check_is_read_by_name(self) -> None:
        api = FakeApi(
            [run("completed", "success")],
            {100: [check("success", "Ship it")]},
        )
        self.assertEqual(verify(api, check="Ship it")[0].verdict, "green")
        self.assertEqual(verify(api)[0].verdict, "no-check")

    def test_an_earlier_attempt_is_not_the_answer(self) -> None:
        """After CI's failed jobs are rerun, the previous attempt's red is
        still listed for a moment; with min_attempt it is waited past."""
        api = FakeApi(
            [run("completed", "failure")] * 3
            + [run("in_progress", attempt=2)]
            + [run("completed", "success", attempt=2)],
            {100: [check("failure")], 200: [check("success")]},
        )
        v, _, _ = verify(api, min_attempt=2)
        self.assertEqual((v.verdict, v.run_attempt), ("green", "2"))


BAD_GATEWAY = "gh: HTTP 502: Bad Gateway (https://api.github.com/x)"


class AnUnansweredReadIsNeverAVerdict(unittest.TestCase):
    """#226 finding 1: the watch's copy read a failed call as an empty
    status, the empty status as "finished", and reran the release while CI
    was still queued."""

    def test_unreadable_polls_are_waited_past(self) -> None:
        api = FakeApi(
            [run("queued")] * 3
            + [vc.Unreadable(BAD_GATEWAY)] * 5
            + [run("queued")] * 3
            + [run("completed", "success")],
            GREEN,
        )
        v, said, _ = verify(api)
        self.assertEqual(v.verdict, "green")
        self.assertEqual(api.polls, 12)
        self.assertTrue(any("never a verdict" in s for s in said), said)

    def test_a_github_that_never_answers_is_unreadable_in_bounds(
        self,
    ) -> None:
        v, _, clock = verify(FakeApi([vc.Unreadable(BAD_GATEWAY)]))
        self.assertEqual(v.verdict, "unreadable")
        self.assertIn("HTTP 502", v.message)
        self.assertLessEqual(sum(clock.sleeps), vc.UNREADABLE + vc.INTERVAL)

    def test_a_refusal_is_a_verdict_at_once(self) -> None:
        api = FakeApi([vc.Refused("gh: HTTP 404: Not Found")])
        v, _, clock = verify(api)
        self.assertEqual(v.verdict, "unreadable")
        self.assertIn("404", v.message)
        self.assertEqual(clock.sleeps, [])


class FakeGh:
    """``subprocess.run`` for ``gh api``: scripted (returncode, stdout,
    stderr) replies, the last repeated."""

    def __init__(self, replies: list[tuple[int, str, str]]) -> None:
        self.replies = replies
        self.calls = 0

    def __call__(
        self, argv: list[str], **kw: Any
    ) -> "subprocess.CompletedProcess[str]":
        assert argv[:2] == ["gh", "api"], argv
        rc, out, err = self.replies[min(self.calls, len(self.replies) - 1)]
        self.calls += 1
        return subprocess.CompletedProcess(argv, rc, out, err)


class OneReadRetriesWhatMayRecover(unittest.TestCase):
    """#226 finding 4: `gh api` retries nothing, and a failed call ended
    jm's verify job on a bare traceback with no ::error::."""

    def read(self, gh: FakeGh) -> tuple[Any, list[float]]:
        slept: list[float] = []
        return (
            vc.gh_api("p", run=gh, sleep=slept.append, say=lambda m: None),
            slept,
        )

    def test_a_5xx_is_retried_with_backoff(self) -> None:
        gh = FakeGh([(1, "", BAD_GATEWAY)] * 2 + [(0, '{"a": 1}', "")])
        got, slept = self.read(gh)
        self.assertEqual(got, {"a": 1})
        self.assertEqual(slept, list(vc.BACKOFF[:2]))

    def test_retries_run_out_as_unreadable(self) -> None:
        gh = FakeGh([(1, "", BAD_GATEWAY)])
        with self.assertRaises(vc.Unreadable) as e:
            self.read(gh)
        self.assertEqual(gh.calls, len(vc.BACKOFF) + 1)
        self.assertIn("HTTP 502", str(e.exception))

    def test_a_rate_limit_is_retried(self) -> None:
        gh = FakeGh(
            [(1, "", "gh: API rate limit exceeded (HTTP 403)")]
            + [(0, "{}", "")]
        )
        self.assertEqual(self.read(gh)[0], {})

    def test_a_refusal_is_not_retried(self) -> None:
        for err in (
            "gh: Not Found (HTTP 404)",
            "gh: Bad credentials (HTTP 401)",
        ):
            with self.subTest(err=err):
                gh = FakeGh([(1, "", err)])
                with self.assertRaises(vc.Refused):
                    self.read(gh)
                self.assertEqual(gh.calls, 1)

    def test_a_reply_that_is_not_json_is_retried(self) -> None:
        gh = FakeGh([(0, "<html>", "")] + [(0, "[]", "")])
        self.assertEqual(self.read(gh)[0], [])


class EveryExitIsNamed(unittest.TestCase):
    """main() prints one ::error:: naming the verdict, and writes it for a
    caller to read."""

    def main(self, v: Any, env: dict[str, str]) -> tuple[int, str, str]:
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        out = tmp / "out"
        buf = io.StringIO()
        real = vc.verify
        vc.verify = lambda *a, **k: v
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            with contextlib.redirect_stdout(buf):
                rc = vc.main(["--out", str(out)])
        finally:
            vc.verify = real
            for k, val in old.items():
                if val is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = val
        text = out.read_text() if out.exists() else ""
        return rc, buf.getvalue(), text

    def test_each_verdict(self) -> None:
        for word in ("red", "no-check", "no-run", "alive", "unreadable"):
            with self.subTest(verdict=word):
                v = vc.Verdict(word, "why", "7", "1", URL)
                rc, said, out = self.main(v, {"REPO": REPO, "SHA": SHA})
                self.assertEqual(rc, 1)
                self.assertTrue(said.startswith(f"::error::[{word}] why"))
                self.assertIn(f"verdict={word}\nrun_id=7\n", out)
        v = vc.Verdict("green", "ok", "7", "1", URL)
        rc, _, out = self.main(v, {"REPO": REPO, "SHA": SHA})
        self.assertEqual(rc, 0)
        self.assertIn("verdict=green", out)

    def test_an_empty_sha_is_refused_not_looked_up(self) -> None:
        """An empty head_sha= filters nothing, and the newest run of ANY
        commit would answer for this one."""
        v = vc.Verdict("green", "ok")
        rc, said, _ = self.main(v, {"REPO": REPO, "SHA": ""})
        self.assertEqual(rc, 2)
        self.assertIn("::error::", said)


BASE = (
    "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\nCLEAN_PATHS = dist/\n"
    "HAS_RELEASE = 1\nBUMP_VERSION_CMD = true\nVERSION_PROBES = a|echo 1\n"
)


class Wiring(unittest.TestCase):
    """standard.mk is the one way to run the script, for both askers."""

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")
        (self.tmp / "scripts").mkdir()
        # Stands in for the vendored script: prints what make handed it.
        (self.tmp / "scripts" / "verify-ci.py").write_text(
            "import os\n"
            "print('verify-ci', os.environ['CI_CHECK_NAME'], "
            "os.environ['CI_WORKFLOW'])\n"
        )

    def make(self, body: str, *args: str) -> str:
        (self.tmp / "Makefile").write_text(
            BASE + body + "include standard.mk\n"
        )
        env = {k: v for k, v in os.environ.items() if k != "MAKEFLAGS"}
        r = subprocess.run(
            ["make", "--no-print-directory", "-s", "-C", str(self.tmp), *args],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_release_verify_ci_runs_the_script_with_the_standards_names(
        self,
    ) -> None:
        out = self.make(
            "RELEASE_WATCH_CMD = true\nCI_CHECK_NAME = Ship it\n"
            "GATES_CI_FILE = .github/workflows/build.yml\n",
            "release-verify-ci",
        )
        self.assertEqual(out.strip(), "verify-ci Ship it build.yml")

    def test_release_watch_hands_the_watch_the_same_names(self) -> None:
        """Exported per target, so a RELEASE_WATCH_CMD of any shape --
        doppler's is an `@`-prefixed define -- receives them."""
        out = self.make(
            "define RELEASE_WATCH_CMD\n"
            '@echo watch "$$CI_CHECK_NAME" "$$CI_WORKFLOW"\n'
            "endef\n",
            "release-watch",
            "VERSION=1.2.3",
        )
        self.assertEqual(out.strip(), "watch CI passed ci.yml")

    def test_the_script_is_vendored_with_release(self) -> None:
        out = self.make("RELEASE_WATCH_CMD = true\n", "standard-files")
        self.assertIn("scripts/verify-ci.py", out.split())

    def test_the_watch_runs_the_vendored_script(self) -> None:
        text = (ROOT / "scripts" / "release-watch.sh").read_text()
        self.assertIn('VERIFY_CI="$(dirname "${BASH_SOURCE[0]}")/', text)
        self.assertIn('python3 -u "$VERIFY_CI"', text)
