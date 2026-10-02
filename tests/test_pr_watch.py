"""Behaviour of scripts/pr-watch.sh's stuck-run detector (just-makeit#1812).

The shape: a PR gets a new head while its previous run is still QUEUED.
The new head's run, in the same concurrency group, sits ``pending`` with
zero jobs until the queued one is force-cancelled; cancel-in-progress does
not cancel it. ``stuck_runs`` reports it, and the watch loop must never
call a PR green while it holds.

``GH`` points the script at a fake that answers from a JSON fixture and
applies the script's OWN ``--jq`` filter with ``jq``, so the filter is
exercised as written, as in test_ci_tree_tested.py. Stdlib only; ``jq`` is
on every Actions runner.

The two stuck fixtures are the real runs from the issue, fetched with
``gh api repos/just-buildit/just-makeit/actions/runs/<id>`` and cut to the
fields a list response carries that matter here. They have finished since,
so ``status``/``conclusion`` are set back to what the issue observed at the
time (superseded: queued; blocked: pending, 0 jobs). ``pull_requests`` is
kept as GitHub returned it -- EMPTY in all four, which is why the detector
matches on branch and workflow instead.
"""

from __future__ import annotations

import copy
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent / "scripts" / "pr-watch.sh"
)
REPO = "just-buildit/just-makeit"
CI = 271252105  # ci.yml's workflow_id in just-makeit
OTHER = 999  # another workflow, e.g. docker.yml


def _run(
    run_id: int,
    sha: str,
    branch: str,
    status: str,
    created: str,
    *,
    workflow: int = CI,
    name: str = "CI",
    attempt: int = 1,
) -> dict:
    return {
        "id": run_id,
        "name": name,
        "workflow_id": workflow,
        "event": "pull_request",
        "status": status,
        "conclusion": None,
        "head_sha": sha,
        "head_branch": branch,
        "run_attempt": attempt,
        "created_at": created,
        "pull_requests": [],
    }


# #1798: the superseded run was a re-run (attempt 2) of the old head.
B1798 = "chore/ci-image-20261002T000000Z-289aff0"
OLD_1798 = _run(
    36946172888,
    "f248d776b818abbac0650b338d837fe9f21dc956",
    B1798,
    "queued",
    "2026-10-02T00:28:35Z",
    attempt=2,
)
NEW_1798 = _run(
    36952820450,
    "39bf50e683fd7cd5050ca8779afa6087406bc657",
    B1798,
    "pending",
    "2026-10-02T01:50:15Z",
)

B1809 = "chore/re-vendor-fa8477f"
OLD_1809 = _run(
    36962530261,
    "d3eb8d0498b143e9acafe022e4b657923c882e07",
    B1809,
    "queued",
    "2026-10-02T03:58:57Z",
)
NEW_1809 = _run(
    36962645315,
    "88344e849bdb9d3c6a36ed2b90f8d2bb1800f2f2",
    B1809,
    "pending",
    "2026-10-02T04:00:32Z",
)

# gh api PATH --jq EXPR, gh pr view/checks ... --jq EXPR; all answered from
# $FAKE_GH_DB, keyed by the api path, or by "pr" / "checks".
FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    cmd="$1 $2"; shift 2
    path= expr=
    while [ $# -gt 0 ]; do
        case "$1" in
            -X|-R|--json) shift 2 ;;
            --jq) expr="$2"; shift 2 ;;
            *) path="$1"; shift ;;
        esac
    done
    case "$cmd" in
        "pr view") key=pr ;;
        "pr checks") key=checks ;;
        api*) key="${cmd#api }" ;;
        *) exit 1 ;;
    esac
    jq -e --arg k "$key" 'has($k)' "$FAKE_GH_DB" >/dev/null || exit 1
    jq --arg k "$key" '.[$k]' "$FAKE_GH_DB" | jq -r "$expr"
    """
)

# The watch loop's only sleep. Reaching it means the loop chose to WAIT
# rather than exit; stopping there makes that choice observable at once.
FAKE_SLEEP = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    echo "<fake sleep: the watcher is waiting>"
    kill -TERM "$PPID"
    """
)


def _runs_key(branch: str) -> str:
    return (
        f"repos/{REPO}/actions/runs?branch={branch}"
        "&event=pull_request&per_page=50"
    )


@unittest.skipUnless(shutil.which("jq"), "the fake gh needs jq")
class StuckRuns(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        for name, text in (("gh", FAKE_GH), ("sleep", FAKE_SLEEP)):
            (bindir / name).write_text(text)
            (bindir / name).chmod(0o755)
        self.bindir = bindir

    def env(self, db: dict) -> dict:
        dbfile = self.tmp / "db.json"
        dbfile.write_text(json.dumps(db))
        return {
            **os.environ,
            "GH": str(self.bindir / "gh"),
            "FAKE_GH_DB": str(dbfile),
        }

    def db(
        self, branch: str, runs: list[dict], jobs: dict[int, int]
    ) -> dict:
        d: dict = {_runs_key(branch): {"workflow_runs": runs}}
        for run_id, n in jobs.items():
            d[f"repos/{REPO}/actions/runs/{run_id}/jobs"] = {"total_count": n}
        return d

    def stuck(
        self, branch: str, head: str, runs: list[dict], jobs: dict[int, int]
    ) -> list[str]:
        r = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; stuck_runs "$2" "$3" "$4"',
                "pr-watch-test",  # $0: NOT the script, or it runs main
                str(SCRIPT),
                REPO,
                head,
                branch,
            ],
            env=self.env(self.db(branch, runs, jobs)),
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.splitlines()

    # The two real cases.
    def test_gh1798_is_stuck(self) -> None:
        got = self.stuck(
            B1798,
            NEW_1798["head_sha"],
            [NEW_1798, OLD_1798],
            {NEW_1798["id"]: 0},
        )
        self.assertEqual(got, ["36952820450 36946172888 f248d776b CI"])

    def test_gh1809_is_stuck(self) -> None:
        got = self.stuck(
            B1809,
            NEW_1809["head_sha"],
            [NEW_1809, OLD_1809],
            {NEW_1809["id"]: 0},
        )
        self.assertEqual(got, ["36962645315 36962530261 d3eb8d049 CI"])

    # Each condition, broken alone from the #1809 shape: all normal.
    def test_a_fresh_pending_run_with_nothing_older_is_not_stuck(self) -> None:
        got = self.stuck(
            B1809, NEW_1809["head_sha"], [NEW_1809], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_waiting_behind_an_in_progress_run_is_not_stuck(self) -> None:
        """Ordinary concurrency: the group is busy, not wedged."""
        old = dict(OLD_1809, status="in_progress")
        got = self.stuck(
            B1809, NEW_1809["head_sha"], [NEW_1809, old], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_a_pending_run_with_jobs_is_not_stuck(self) -> None:
        got = self.stuck(
            B1809,
            NEW_1809["head_sha"],
            [NEW_1809, OLD_1809],
            {NEW_1809["id"]: 13},
        )
        self.assertEqual(got, [])

    def test_a_queued_run_not_pending_is_not_stuck(self) -> None:
        new = dict(NEW_1809, status="queued")
        got = self.stuck(
            B1809, new["head_sha"], [new, OLD_1809], {new["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_another_workflows_queued_run_does_not_block(self) -> None:
        old = dict(OLD_1809, workflow_id=OTHER, name="Docker")
        got = self.stuck(
            B1809, NEW_1809["head_sha"], [NEW_1809, old], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_a_queued_run_on_the_same_head_is_not_superseded(self) -> None:
        old = dict(OLD_1809, head_sha=NEW_1809["head_sha"])
        got = self.stuck(
            B1809, NEW_1809["head_sha"], [NEW_1809, old], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_a_newer_queued_run_does_not_block_an_older_one(self) -> None:
        old = dict(OLD_1809, created_at="2026-10-02T04:05:00Z")
        got = self.stuck(
            B1809, NEW_1809["head_sha"], [NEW_1809, old], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    def test_a_pending_run_for_another_head_is_not_reported(self) -> None:
        """Only the PR's current head is the watcher's business."""
        got = self.stuck(
            B1809, "0" * 40, [NEW_1809, OLD_1809], {NEW_1809["id"]: 0}
        )
        self.assertEqual(got, [])

    # The report, and the loop's use of it.
    def test_the_report_names_both_runs_and_force_cancel(self) -> None:
        r = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; report_stuck "$2" "$3"',
                "pr-watch-test",  # $0: NOT the script, or it runs main
                str(SCRIPT),
                REPO,
                "36962645315 36962530261 d3eb8d049 CI",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("run 36962645315 (CI) is pending with 0 jobs", r.stdout)
        self.assertIn("run 36962530261,", r.stdout)
        self.assertIn(
            f"gh api -X POST repos/{REPO}/actions/runs/36962530261/"
            "force-cancel",
            r.stdout,
        )

    def watch(self, stuck: bool) -> subprocess.CompletedProcess[str]:
        """Run the real loop: PR open, every OTHER workflow's check green."""
        new = copy.deepcopy(NEW_1809)
        db = self.db(B1809, [new, OLD_1809], {new["id"]: 0 if stuck else 9})
        db["pr"] = {
            "state": "OPEN",
            "headRefOid": new["head_sha"],
            "headRefName": B1809,
        }
        db["checks"] = [{"name": "Docker image", "bucket": "pass"}]
        env = self.env(db)
        env.update(
            REPO=REPO,
            PATH=f"{self.bindir}{os.pathsep}{env['PATH']}",
            INTERVAL="0",
            QUIET="0",
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "1809"],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_a_stuck_pr_is_reported_and_never_green(self) -> None:
        r = self.watch(stuck=True)
        self.assertIn("force-cancel", r.stdout)
        self.assertIn("<fake sleep: the watcher is waiting>", r.stdout)
        self.assertNotIn("settled green", r.stdout)

    def test_an_unstuck_pr_with_green_checks_is_green(self) -> None:
        r = self.watch(stuck=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("all 1 checks settled green", r.stdout)
        self.assertNotIn("force-cancel", r.stdout)


if __name__ == "__main__":
    unittest.main()
