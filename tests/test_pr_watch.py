"""Behaviour of scripts/pr-watch.sh: its stuck-run detector (just-makeit#1812),
and what it does when gh cannot answer (just-buildit.github.io#113).

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

The gh failures are recorded too: what gh printed on stderr, and its exit
code, measured 2026-10-05 against this repo's PRs. gh 2.46.0 is Debian 13's
package; 2.49.2 rejects ``--json`` with the same words, and 2.50.0 is the
first release that takes it (cli/cli#9079, measured with both binaries).
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
#
# A read is "<key>:<--json fields>" ("pr:state", "<api path>:"), and each one
# made is appended to $FAKE_GH_LOG. A db entry "fail:<read>", or "fail:<key>"
# for every read of that key, makes it fail as gh did: {"stderr", "rc"}.
# `gh --version` prints the db's "version".
FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    if [ "$1" = --version ]; then
        jq -er '.version // empty' "$FAKE_GH_DB"; exit
    fi
    cmd="$1 $2"; shift 2
    path= expr= fields=
    while [ $# -gt 0 ]; do
        case "$1" in
            -X|-R) shift 2 ;;
            --json) fields="$2"; shift 2 ;;
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
    [ -n "${FAKE_GH_LOG:-}" ] && echo "$key:$fields" >>"$FAKE_GH_LOG"
    for f in "fail:$key:$fields" "fail:$key"; do
        if jq -e --arg k "$f" 'has($k)' "$FAKE_GH_DB" >/dev/null; then
            jq -r --arg k "$f" '.[$k].stderr' "$FAKE_GH_DB" >&2
            exit "$(jq -r --arg k "$f" '.[$k].rc' "$FAKE_GH_DB")"
        fi
    done
    jq -e --arg k "$key" 'has($k)' "$FAKE_GH_DB" >/dev/null || exit 1
    jq --arg k "$key" '.[$k]' "$FAKE_GH_DB" | jq -r "$expr"
    """
)

# The watch loop's only sleep. Reaching it means the loop chose to WAIT
# rather than exit; stopping there makes that choice observable at once.
WAITING = "<fake sleep: the watcher is waiting>"
FAKE_SLEEP = textwrap.dedent(
    f"""\
    #!/usr/bin/env bash
    echo "{WAITING}"
    kill -TERM "$PPID"
    """
)


def _runs_key(branch: str) -> str:
    return (
        f"repos/{REPO}/actions/runs?branch={branch}"
        "&event=pull_request&per_page=50"
    )


# What gh said, as {"stderr", "rc"}: see the module docstring.
OLD_GH = (
    "gh version 2.46.0 (2025-01-13 Debian 2.46.0-3)\n"
    "https://github.com/cli/cli/releases/tag/v2.46.0"
)
NO_JSON = {  # cut after the usage line; the flag list follows it
    "rc": 1,
    "stderr": "unknown flag: --json\n\n"
    "Usage:  gh pr checks [<number> | <url> | <branch>] [flags]\n",
}
NO_AUTH = {
    "rc": 4,
    "stderr": "To get started with GitHub CLI, please run:  gh auth login\n"
    "Alternatively, populate the GH_TOKEN environment variable with a "
    "GitHub API authentication token.",
}
BAD_TOKEN = {
    "rc": 1,
    "stderr": "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"
    "Try authenticating with:  gh auth login",
}
OFFLINE = {
    "rc": 1,
    "stderr": 'Post "https://api.github.com/graphql": proxyconnect tcp: '
    "dial tcp 127.0.0.1:9: connect: connection refused",
}
# gh >= 2.50's answer for a PR with no checks yet: an ERROR, not `[]`.
NO_CHECKS = {
    "rc": 1,
    "stderr": f"no checks reported on the '{B1809}' branch",
}


@unittest.skipUnless(shutil.which("jq"), "the fake gh needs jq")
class FakeGh(unittest.TestCase):
    """A fake gh and sleep on PATH, and the real watch loop over them."""

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

    def watch(
        self, stuck: bool = False, **extra: object
    ) -> subprocess.CompletedProcess[str]:
        """Run the real loop: PR open, every OTHER workflow's check green.

        ``extra`` adds db entries -- a ``version``, or a ``fail:<read>``.
        """
        new = copy.deepcopy(NEW_1809)
        db = self.db(B1809, [new, OLD_1809], {new["id"]: 0 if stuck else 9})
        db["pr"] = {
            "state": "OPEN",
            "headRefOid": new["head_sha"],
            "headRefName": B1809,
        }
        db["checks"] = [{"name": "Docker image", "bucket": "pass"}]
        db.update(extra)
        env = self.env(db)
        env.update(
            REPO=REPO,
            PATH=f"{self.bindir}{os.pathsep}{env['PATH']}",
            INTERVAL="0",
            QUIET="0",
            FAKE_GH_LOG=str(self.tmp / "reads.log"),
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "1809"],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def reads(self) -> list[str]:
        """Every read the last watch() made, in order."""
        return (self.tmp / "reads.log").read_text().splitlines()


class StuckRuns(FakeGh):
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

    def test_a_stuck_pr_is_reported_and_never_green(self) -> None:
        r = self.watch(stuck=True)
        self.assertIn("force-cancel", r.stdout)
        self.assertIn(WAITING, r.stdout)
        self.assertNotIn("settled green", r.stdout)

    def test_an_unstuck_pr_with_green_checks_is_green(self) -> None:
        r = self.watch(stuck=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("all 1 checks settled green", r.stdout)
        self.assertNotIn("force-cancel", r.stdout)


# Every read the loop makes before a verdict, in a green run's order. A read
# the verdict depends on, failing alone, must never be read as an answer.
READS = [
    "pr:state",
    "pr:headRefOid",
    "pr:headRefName",
    f"{_runs_key(B1809)}:",
    f"repos/{REPO}/actions/runs/{NEW_1809['id']}/jobs:",
    "checks:name",
    "checks:bucket",
    "checks:name,bucket",
]


class GhCannotAnswer(FakeGh):
    """just-buildit.github.io#113: a failed gh call is not an empty answer."""

    def test_the_reads_are_every_read(self) -> None:
        """READS is what the loop asks, so no read below goes untested."""
        r = self.watch()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.reads(), READS)

    def test_a_gh_without_pr_checks_json_stops_at_once(self) -> None:
        """The issue: Debian's gh 2.46.0 waited out the whole timeout."""
        r = self.watch(version=OLD_GH, **{"fail:checks": NO_JSON})
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertNotIn(WAITING, r.stdout)  # within the first poll
        self.assertNotIn("no checks reported yet", r.stdout)
        self.assertIn("unknown flag: --json", r.stdout)
        self.assertIn("gh version 2.46.0", r.stdout)  # what is installed
        self.assertIn("gh >= 2.50.0", r.stdout)  # and what it needs

    def test_a_gh_that_cannot_authenticate_stops_at_once(self) -> None:
        for read in READS:
            for said in (NO_AUTH, BAD_TOKEN):
                with self.subTest(read=read, rc=said["rc"]):
                    r = self.watch(**{f"fail:{read}": said})
                    self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                    self.assertNotIn(WAITING, r.stdout)
                    self.assertIn("gh cannot authenticate", r.stdout)
                    self.assertIn(said["stderr"].splitlines()[0], r.stdout)

    def test_any_other_gh_error_is_named_and_never_a_verdict(self) -> None:
        """Offline: wait, saying why. Read as empty, five of these failing
        reads let the loop call the PR green without them."""
        for read in READS:
            with self.subTest(read=read):
                r = self.watch(**{f"fail:{read}": OFFLINE})
                self.assertIn(WAITING, r.stdout)
                self.assertNotIn("settled green", r.stdout)
                self.assertNotIn("no checks reported yet", r.stdout)
                self.assertIn(
                    f"gh exited 1: {OFFLINE['stderr']} — retrying (not green)",
                    r.stdout,
                )

    def test_a_failed_read_never_calls_an_unsettled_pr_green(self) -> None:
        """Where the green above was also WRONG: a check pending or red."""
        for read, bucket in (
            ("checks:bucket", "pending"),
            ("checks:name,bucket", "fail"),
        ):
            with self.subTest(read=read, bucket=bucket):
                r = self.watch(
                    checks=[
                        {"name": "Docker image", "bucket": "pass"},
                        {"name": "test", "bucket": bucket},
                    ],
                    **{f"fail:{read}": OFFLINE},
                )
                self.assertNotIn("settled green", r.stdout)
                self.assertIn(WAITING, r.stdout)

    def test_gh_answering_no_checks_with_an_error_still_waits(self) -> None:
        """gh >= 2.50 fails a PR with no checks yet: that is failure mode 2."""
        r = self.watch(**{"fail:checks": NO_CHECKS})
        self.assertIn(
            f"no checks reported yet for {NEW_1809['head_sha'][:9]}"
            " — waiting (not green)",
            r.stdout,
        )
        self.assertIn(WAITING, r.stdout)
        self.assertNotIn("gh exited", r.stdout)


if __name__ == "__main__":
    unittest.main()
