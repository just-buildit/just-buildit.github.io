"""Behaviour of scripts/release-watch.sh's hung-runner detector
(just-buildit.github.io#70, #140).

A pre-publish job in progress longer than HANG_MIN (25 min) was cancelled
as a hung runner, spending the watch's one recovery. A release's verify
job polls main's CI by design for up to an hour (just-makeit's has
``timeout-minutes: 75``), so it was cancelled while healthy on
just-makeit v0.93.0, v0.104.0, v0.105.0, v0.106.0 and v0.106.1. A job is
hung only past the time its own workflow allows it: the script reads each
job's ``timeout-minutes`` from release.yml at the tag.

The real script runs end to end over fakes on PATH: ``gh`` answers from
the fixtures below and applies the script's OWN ``--jq`` filters with
``jq``; ``git`` answers the tag lookup; ``sleep`` stops the script, since
reaching one means the watch chose to wait (or, after a cancel, to let the
rerun start). Each gh call is logged, so a cancel is observed as made, not
inferred from a message. Without jq each class FAILS, naming it (#121).
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "release-watch.sh"
)
REPO = "just-buildit/just-makeit"
VERSION = "0.106.1"
SHA = "0123456789abcdef0123456789abcdef01234567"
RUN = 38462742575

# The shapes a real release.yml has: a job named, one unnamed (its id is
# its name), a matrix whose name carries an expression, a step-level
# timeout that is not the job's, a quoted name, and a job with no timeout.
WORKFLOW = textwrap.dedent(
    """\
    name: Release
    on:
      push:
        tags: ["v*"]

    jobs:
      # The verify job polls main's CI for up to 60 minutes.
      verify-ci:
        name: Verify CI already passed for this commit
        runs-on: ubuntu-latest
        timeout-minutes: 75   # above the 60-minute poll window
        steps:
          - run: ./poll.sh

      build:
        runs-on: ubuntu-latest
        timeout-minutes: 15
        steps:
          - run: make wheel
            timeout-minutes: 90

      wheels:
        name: "Build wheels (manylinux ${{ matrix.arch }})"
        strategy:
          matrix:
            arch: [x86_64, aarch64]
        timeout-minutes: 45
        steps:
          - run: make wheel

      smoke:
        name: Smoke test the wheel
        runs-on: ubuntu-latest
        steps:
          - run: make smoke

      publish:
        needs: [verify-ci, build, smoke]
        timeout-minutes: 10
        steps:
          - run: twine upload dist/*
    """
)

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    if [ "$1" = run ]; then cmd="$1 $2"; shift 2; else cmd="$1"; shift; fi
    expr= path=
    while [ $# -gt 0 ]; do
        case "$1" in
            -R|-H|-L|--json|--workflow) shift 2 ;;
            --workflow=*|--paginate|--failed) shift ;;
            --jq) expr="$2"; shift 2 ;;
            *) path="$1"; shift ;;
        esac
    done
    echo "$cmd $path" >>"$FAKE_GH_LOG"
    case "$cmd" in
        "run list") json="$FAKE_RUNS" ;;
        "run view") json="$FAKE_RUN" ;;
        "run cancel"|"run rerun") exit 0 ;;
        api)
            case "$path" in
                */contents/.github/workflows/release.yml\\?ref=*)
                    [ -f "$FAKE_WORKFLOW" ] || exit 1
                    cat "$FAKE_WORKFLOW"; exit 0 ;;
                # CI's push runs for a SHA (#226): one reply per line of
                # FAKE_CI_RUNS, one line per call, the last repeated. A line
                # `ERROR <text>` is a failed call: gh prints <text> on stderr
                # and exits 1, as it does for an HTTP error.
                */actions/workflows/*/runs\\?*)
                    [ -n "${FAKE_CI_RUNS:-}" ] || exit 1
                    n=$(( $(cat "$FAKE_CI_RUNS.n" 2>/dev/null || echo 0) + 1 ))
                    echo "$n" >"$FAKE_CI_RUNS.n"
                    total=$(wc -l <"$FAKE_CI_RUNS")
                    [ "$n" -le "$total" ] || n=$total
                    line=$(sed -n "${n}p" "$FAKE_CI_RUNS")
                    case "$line" in
                        ERROR*) echo "${line#ERROR }" >&2; exit 1 ;;
                    esac
                    json="$FAKE_CI_RUNS.cur"
                    printf '%s\\n' "$line" >"$json" ;;
                # A check suite's check-runs: FAKE_CHECKS maps a suite id to
                # its `CI passed` check-run.
                */check-suites/*/check-runs\\?*)
                    [ -n "${FAKE_CHECKS:-}" ] || exit 1
                    id=${path#*/check-suites/}; id=${id%%/*}
                    json="$FAKE_CHECKS.cur"
                    jq --arg id "$id" '[.[$id] // empty]
                        | {total_count: length, check_runs: .}' \\
                        "$FAKE_CHECKS" >"$json" ;;
                *) exit 1 ;;
            esac ;;
        *) exit 1 ;;
    esac
    if [ -n "$expr" ]; then jq -r "$expr" "$json"; else cat "$json"; fi
    """
)

FAKE_GIT = textwrap.dedent(
    f"""\
    #!/usr/bin/env bash
    [ "$1" = ls-remote ] || exit 1
    printf '{SHA}\\trefs/tags/v{VERSION}^{{}}\\n'
    """
)

# Reaching a sleep means the watch chose to wait; stop it there.
WAITING = "<fake sleep: the watcher is waiting>"
FAKE_SLEEP = textwrap.dedent(
    f"""\
    #!/usr/bin/env bash
    echo "{WAITING}"
    kill -TERM "$PPID"
    """
)


def _ago(minutes: int) -> str:
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
        minutes=minutes
    )
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


class Fakes(unittest.TestCase):
    """The fake gh, git and sleep on PATH, and a scratch dir per test."""

    @classmethod
    def setUpClass(cls) -> None:
        # Fail, never skip: unittest reports a skip as OK (#121).
        if shutil.which("jq") is None:
            raise RuntimeError(
                "jq is not on PATH: release-watch.sh and the fake gh both "
                "run jq filters, so these tests cannot run without it. "
                "Install jq."
            )

    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.bindir = self.tmp / "bin"
        self.bindir.mkdir()
        for name, text in (
            ("gh", FAKE_GH),
            ("git", FAKE_GIT),
            ("sleep", FAKE_SLEEP),
        ):
            (self.bindir / name).write_text(text)
            (self.bindir / name).chmod(0o755)
        self.log = self.tmp / "gh.log"
        self.workflow = self.tmp / "release.yml"
        self.workflow.write_text(WORKFLOW)


class ReleaseWatch(Fakes):
    def watch(
        self, jobs: dict[str, int], *, workflow: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Run the watch over one in-progress run.

        ``jobs`` maps each in-progress job's run-time name to the minutes
        it has been running.
        """
        if not workflow:
            self.workflow.unlink()
        self.log.write_text("")
        runs = self.tmp / "runs.json"
        runs.write_text(
            json.dumps(
                [
                    {
                        "databaseId": RUN,
                        "headBranch": f"v{VERSION}",
                        "headSha": SHA,
                    }
                ]
            )
        )
        run = self.tmp / "run.json"
        run.write_text(
            json.dumps(
                {
                    "status": "in_progress",
                    "conclusion": "",
                    "headSha": SHA,
                    "jobs": [
                        {
                            "name": name,
                            "status": "in_progress",
                            "conclusion": None,
                            "startedAt": _ago(minutes),
                        }
                        for name, minutes in jobs.items()
                    ]
                    + [
                        {
                            "name": "publish",
                            "status": "queued",
                            "conclusion": None,
                            "startedAt": None,
                        }
                    ],
                }
            )
        )
        env = {
            **os.environ,
            "PATH": f"{self.bindir}{os.pathsep}{os.environ['PATH']}",
            "REPO": REPO,
            "RW_PKG": "just-makeit",
            "FAKE_GH_LOG": str(self.log),
            "FAKE_RUNS": str(runs),
            "FAKE_RUN": str(run),
            "FAKE_WORKFLOW": str(self.workflow),
        }
        env.pop("HANG_MIN", None)
        r = subprocess.run(
            ["bash", str(SCRIPT), VERSION],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        # Armed: the watch reached its loop and stopped at a sleep, rather
        # than failing earlier for a reason of the harness's own.
        self.assertIn(WAITING, r.stdout, r.stdout + r.stderr)
        return r

    def cancelled(self) -> bool:
        return any(
            line.startswith("run cancel ")
            for line in self.log.read_text().splitlines()
        )

    def test_the_workflow_is_read_at_the_tagged_commit(self) -> None:
        self.watch({})
        self.assertIn(
            f"api repos/{REPO}/contents/.github/workflows/release.yml"
            f"?ref={SHA}",
            self.log.read_text().splitlines(),
        )

    # The case from the issues: the verify job, polling by design.
    def test_verify_job_40m_into_its_75m_timeout_is_not_cancelled(
        self,
    ) -> None:
        r = self.watch(
            {"Verify CI already passed for this commit": 40, "build": 3}
        )
        self.assertFalse(self.cancelled(), r.stdout)
        self.assertNotIn("hung runner", r.stdout)

    def test_build_job_40m_into_its_15m_timeout_is_cancelled(self) -> None:
        r = self.watch({"build": 40})
        self.assertTrue(self.cancelled(), r.stdout)
        self.assertIn("'build' stuck >25m (hung runner)", r.stdout)

    def test_job_with_no_timeout_keeps_hang_min(self) -> None:
        r = self.watch({"Smoke test the wheel": 40})
        self.assertTrue(self.cancelled(), r.stdout)
        self.assertIn(">25m", r.stdout)

    def test_a_job_past_its_own_timeout_and_margin_is_cancelled(self) -> None:
        """GitHub did not end it: the backstop still fires, at 75 + 5."""
        r = self.watch({"Verify CI already passed for this commit": 81})
        self.assertTrue(self.cancelled(), r.stdout)
        self.assertIn(">80m (hung runner)", r.stdout)

    def test_a_matrix_leg_reads_its_jobs_timeout(self) -> None:
        r = self.watch({"Build wheels (manylinux aarch64)": 40})
        self.assertFalse(self.cancelled(), r.stdout)
        r = self.watch({"Build wheels (manylinux aarch64)": 51})
        self.assertTrue(self.cancelled(), r.stdout)
        self.assertIn(">50m", r.stdout)

    def test_a_steps_timeout_is_not_the_jobs(self) -> None:
        """`build` has a 90-minute STEP; the job's own limit is 15."""
        self.watch({"build": 40})
        self.assertTrue(self.cancelled())

    def test_an_unreadable_workflow_falls_back_to_hang_min(self) -> None:
        r = self.watch(
            {"Verify CI already passed for this commit": 40},
            workflow=False,
        )
        self.assertIn("no job timeouts read from release.yml", r.stdout)
        self.assertTrue(self.cancelled(), r.stdout)


CI_RUN = 42998505736
VERIFY = "Verify CI already passed for this commit"
CI_URL = f"https://github.com/{REPO}/actions/runs/{CI_RUN}"
BAD_GATEWAY = "ERROR gh: HTTP 502: Bad Gateway (https://api.github.com/...)"

# verify-ci.py's clock, in the child Python the watch runs: a sleep returns
# at once and advances a fake monotonic clock by its length, and each one
# is logged. So a 75-minute wait costs no time, and the bound it is held to
# is the script's own arithmetic, not a test knob in the product.
SITECUSTOMIZE = textwrap.dedent(
    """\
    import os, time
    _now = [0.0]
    def _sleep(s):
        _now[0] += s
        with open(os.environ["FAKE_PY_SLEEPS"], "a") as f:
            f.write(f"{s}\\n")
    time.sleep = _sleep
    time.monotonic = lambda: _now[0]
    """
)


def _ci(
    status: str,
    conclusion: str | None = None,
    *,
    attempt: int = 1,
) -> str:
    """One Actions-API reply listing CI's push run for the SHA, shaped like
    GET /repos/{o}/{r}/actions/workflows/{id}/runs. Each attempt has its
    own check suite, ``attempt`` * 100."""
    return json.dumps(
        {
            "total_count": 1,
            "workflow_runs": [
                {
                    "id": CI_RUN,
                    "run_attempt": attempt,
                    "head_sha": SHA,
                    "head_branch": "main",
                    "event": "push",
                    "status": status,
                    "conclusion": conclusion,
                    "check_suite_id": attempt * 100,
                    "html_url": CI_URL,
                }
            ],
        }
    )


NO_RUN = json.dumps({"total_count": 0, "workflow_runs": []})


def _check(conclusion: str) -> dict[str, object]:
    return {
        "name": "CI passed",
        "status": "completed",
        "conclusion": conclusion,
        "html_url": f"{CI_URL}/job/1",
    }


class VerifyGaveUpOnALiveCI(Fakes):
    """just-buildit.github.io#226: the verify job timed out while main's CI
    for the tag was still queued (no jobs, so no `CI passed` check-run),
    and the watch spent its one recovery on a release rerun that hit the
    same wall. The watch now asks verify-ci.py -- the script the verify job
    runs -- and spends the recovery only on a verdict a rerun can change.
    """

    def failed_verify(
        self,
        ci: list[str],
        *,
        checks: dict[int, dict[str, object]] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Run the watch over a COMPLETED release run whose verify job
        failed; ``ci`` is gh's reply to each successive CI lookup."""
        self.log.write_text("")
        runs = self.tmp / "runs.json"
        runs.write_text(
            json.dumps(
                [
                    {
                        "databaseId": RUN,
                        "headBranch": f"v{VERSION}",
                        "headSha": SHA,
                    }
                ]
            )
        )
        run = self.tmp / "run.json"
        run.write_text(
            json.dumps(
                {
                    "status": "completed",
                    "conclusion": "failure",
                    "headSha": SHA,
                    "jobs": [
                        {
                            "name": VERIFY,
                            "status": "completed",
                            "conclusion": "failure",
                            "startedAt": _ago(80),
                        },
                        {
                            "name": "publish",
                            "status": "completed",
                            "conclusion": "skipped",
                            "startedAt": None,
                        },
                    ],
                }
            )
        )
        ci_runs = self.tmp / "ci-runs.jsonl"
        ci_runs.write_text("".join(line + "\n" for line in ci))
        site = self.tmp / "site"
        site.mkdir(exist_ok=True)
        (site / "sitecustomize.py").write_text(SITECUSTOMIZE)
        self.py_sleeps = self.tmp / "py-sleeps"
        self.py_sleeps.write_text("")
        env = {
            **os.environ,
            "PATH": f"{self.bindir}{os.pathsep}{os.environ['PATH']}",
            "PYTHONPATH": str(site),
            "FAKE_PY_SLEEPS": str(self.py_sleeps),
            "REPO": REPO,
            "RW_PKG": "just-makeit",
            "FAKE_GH_LOG": str(self.log),
            "FAKE_RUNS": str(runs),
            "FAKE_RUN": str(run),
            "FAKE_WORKFLOW": str(self.workflow),
            "FAKE_CI_RUNS": str(ci_runs),
        }
        for k in ("CI_CHECK_NAME", "CI_WORKFLOW"):
            env.pop(k, None)
        f = self.tmp / "checks.json"
        f.write_text(
            json.dumps({str(k): v for k, v in (checks or {}).items()})
        )
        env["FAKE_CHECKS"] = str(f)
        return subprocess.run(
            ["bash", str(SCRIPT), VERSION],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def calls(self, prefix: str) -> list[str]:
        return [
            line
            for line in self.log.read_text().splitlines()
            if line.startswith(prefix)
        ]

    def ci_polls(self) -> int:
        return len(
            [c for c in self.calls("api ") if "/actions/workflows/" in c]
        )

    def waited_s(self) -> float:
        return sum(float(x) for x in self.py_sleeps.read_text().split())

    def assert_released_after_ci(self, out: str) -> None:
        """The recovery is the RELEASE rerun, made once, after the last CI
        lookup."""
        self.assertIn(f"run rerun {RUN}", self.calls("run rerun "), out)
        log = self.log.read_text().splitlines()
        last_ci = max(
            i for i, c in enumerate(log) if "/actions/workflows/" in c
        )
        self.assertGreater(log.index(f"run rerun {RUN}"), last_ci, out)

    def assert_recovery_unspent(self, r: subprocess.CompletedProcess[str]):
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 1, out)
        self.assertEqual(self.calls("run rerun "), [], out)
        self.assertIn("The one recovery is NOT spent", out)

    def test_a_queued_then_running_ci_is_waited_for_then_released(
        self,
    ) -> None:
        r = self.failed_verify(
            [_ci("pending")] * 5
            + [_ci("in_progress")] * 5
            + [_ci("completed", "success")],
            checks={100: _check("success")},
        )
        out = r.stdout + r.stderr
        self.assertIn(WAITING, r.stdout, out)
        self.assertEqual(self.ci_polls(), 11, out)
        self.assertIn(f"CI run {CI_URL} is pending", out)
        self.assertIn("CI is green — rerunning the release run", out)
        self.assertEqual(self.calls("run rerun "), [f"run rerun {RUN}"])
        self.assert_released_after_ci(out)

    def test_a_failed_lookup_is_never_a_finished_ci(self) -> None:
        """Finding 1 on #227: a failed API call read as an empty status, the
        wait ended ("finished: <none>"), no `CI passed` check existed yet,
        and the release was rerun while CI was still queued -- v0.128.0's
        failure, from one bad reply. A failed lookup is retried and waited
        past; the release is rerun only once CI is green."""
        r = self.failed_verify(
            [_ci("queued")] * 2
            + [BAD_GATEWAY] * 6
            + [_ci("queued")] * 2
            + [_ci("completed", "success")],
            checks={100: _check("success")},
        )
        out = r.stdout + r.stderr
        self.assertIn(WAITING, r.stdout, out)
        self.assertEqual(self.ci_polls(), 11, out)
        self.assertIn("HTTP 502", out)
        self.assertIn("CI is green — rerunning the release run", out)
        self.assert_released_after_ci(out)

    def test_the_ci_lookup_is_by_sha_on_mains_push_runs(self) -> None:
        self.failed_verify(
            [_ci("completed", "success")], checks={100: _check("success")}
        )
        log = self.log.read_text().splitlines()
        self.assertIn(
            f"api repos/{REPO}/actions/workflows/ci.yml/runs"
            f"?head_sha={SHA}&branch=main&event=push&per_page=10",
            log,
        )
        self.assertIn(
            f"api repos/{REPO}/check-suites/100/check-runs"
            f"?check_name=CI%20passed",
            log,
        )

    def test_the_wait_is_the_verify_jobs_own_timeout(self) -> None:
        """No second number: the verify job's `timeout-minutes` (75 in the
        fixture) bounds the wait, and past it the watch stops unspent."""
        r = self.failed_verify([_ci("queued")])
        out = r.stdout + r.stderr
        self.assert_recovery_unspent(r)
        self.assertIn("up to 75m", out)
        self.assertIn("'alive'", out)
        self.assertEqual(self.waited_s(), 75 * 60, out)
        self.assertIn(CI_URL, out)

    def test_a_verify_job_without_a_timeout_waits_githubs_maximum(
        self,
    ) -> None:
        self.workflow.write_text(
            WORKFLOW.replace(
                "    timeout-minutes: 75   # above the 60-minute poll window\n",
                "",
            )
        )
        r = self.failed_verify(
            [_ci("queued"), _ci("completed", "success")],
            checks={100: _check("success")},
        )
        self.assertIn("up to 360m", r.stdout, r.stdout + r.stderr)

    def test_a_ci_that_finishes_red_takes_the_ci_repair(self) -> None:
        """Rerun CI's failed jobs, wait for THAT attempt (the previous
        one's red, still listed for a moment, is not its answer), and rerun
        the release once it is green."""
        r = self.failed_verify(
            [_ci("in_progress"), _ci("completed", "failure")]
            + [_ci("completed", "failure")] * 2  # the rerun not yet seen
            + [
                _ci("queued", attempt=2),
                _ci("completed", "success", attempt=2),
            ],
            checks={100: _check("failure"), 200: _check("success")},
        )
        out = r.stdout + r.stderr
        self.assertIn(WAITING, r.stdout, out)
        self.assertEqual(
            self.calls("run rerun "),
            [f"run rerun {CI_RUN}", f"run rerun {RUN}"],
            out,
        )
        self.assert_released_after_ci(out)

    def test_a_ci_still_red_after_its_rerun_stops(self) -> None:
        r = self.failed_verify(
            [
                _ci("completed", "failure"),
                _ci("completed", "failure", attempt=2),
            ],
            checks={100: _check("failure"), 200: _check("failure")},
        )
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 1, out)
        self.assertEqual(self.calls("run rerun "), [f"run rerun {CI_RUN}"])
        self.assertIn("CI still red", out)

    def test_a_cancelled_ci_stops_without_the_recovery(self) -> None:
        """Finding 5: superseded before `CI passed` existed. No rerun of the
        release can certify the commit, so the watch says so and keeps the
        recovery for after a human reruns CI."""
        r = self.failed_verify([_ci("completed", "cancelled")])
        self.assert_recovery_unspent(r)
        self.assertIn("'no-check'", r.stdout)
        self.assertIn("make release-watch VERSION=0.106.1", r.stdout)

    def test_a_ci_that_never_ran_stops_without_the_recovery(self) -> None:
        r = self.failed_verify([NO_RUN])
        self.assert_recovery_unspent(r)
        self.assertIn("'no-run'", r.stdout)

    def test_a_github_that_never_answers_stops_without_the_recovery(
        self,
    ) -> None:
        r = self.failed_verify([BAD_GATEWAY])
        self.assert_recovery_unspent(r)
        self.assertIn("'unreadable'", r.stdout)

    def test_a_verify_ci_that_crashed_is_not_a_finished_ci(self) -> None:
        """A reply of an unexpected shape crashes the script before any
        verdict: no answer, so the recovery stays unspent."""
        r = self.failed_verify(["[]"])
        self.assert_recovery_unspent(r)
        self.assertIn("Traceback", r.stdout)
        self.assertIn("'unreadable'", r.stdout)

    def test_a_ci_already_green_reruns_the_release_at_once(self) -> None:
        r = self.failed_verify(
            [_ci("completed", "success")], checks={100: _check("success")}
        )
        self.assertEqual(self.ci_polls(), 1, r.stdout)
        self.assertEqual(self.waited_s(), 0, r.stdout)
        self.assertEqual(self.calls("run rerun "), [f"run rerun {RUN}"])


class OneImplementation(unittest.TestCase):
    """The watch's CI question is verify-ci.py's: a lookup of its own here
    is the peer that drifted (#226 finding 1)."""

    def test_the_watch_has_no_ci_lookup_of_its_own(self) -> None:
        code = "\n".join(
            line
            for line in SCRIPT.read_text().splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertIn("verify-ci.py", code)
        for own in ("actions/workflows/", "check-runs", "CI passed"):
            self.assertNotIn(own, code)


if __name__ == "__main__":
    unittest.main()
