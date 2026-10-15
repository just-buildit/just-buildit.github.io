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
            esac
            exit 1 ;;
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


class ReleaseWatch(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
