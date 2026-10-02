"""Behaviour of scripts/ci-tree-tested.sh, over a real temporary git repo.

The script asks GitHub three questions through ``gh api``. ``GH`` points it
at a fake that answers from a JSON fixture and applies the script's OWN
``--jq`` filter with ``jq``, so the filters are exercised as written: which
PRs count as merged, which app's check-run counts, and which run is newest.
Stdlib only, like the other tests here; ``jq`` is on every Actions runner.

Each case starts from the one shape that should skip -- a branch based on
the tip, merged with the same tree, green as a PR -- and breaks exactly one
condition, so each check in the script is shown to be load-bearing.
"""

from __future__ import annotations

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
    / "ci-tree-tested.sh"
)
REPO = "o/r"

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # gh api [-X GET] PATH [-f k=v]... --jq EXPR, answered from $FAKE_GH_DB.
    shift                                  # "api"
    path= expr=
    while [ $# -gt 0 ]; do
        case "$1" in
            -X) shift 2 ;;
            -f) path_q="${path_q}${path_q:+&}$2"; shift 2 ;;
            --jq) expr="$2"; shift 2 ;;
            *) path="$1"; shift ;;
        esac
    done
    key="$path${path_q:+?$path_q}"
    jq -e --arg k "$key" 'has($k)' "$FAKE_GH_DB" >/dev/null || exit 1
    jq --arg k "$key" '.[$k]' "$FAKE_GH_DB" | jq -r "$expr"
    """
)


@unittest.skipUnless(shutil.which("jq"), "the fake gh needs jq")
class CiTreeTested(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        self.before = self.commit("a.txt", "1")  # the tip the push replaced
        self.pr_head = self.commit("a.txt", "2")  # the PR, based on the tip
        self.pr_tree = self.git("rev-parse", "HEAD^{tree}")
        # A rebase merge re-creates the commit: same tree, new identity.
        self.git("reset", "-q", "--hard", self.before)
        self.git("checkout", "-q", self.pr_head, "--", ".")
        self.git("commit", "-q", "-m", "rebased", "--date", "2001-01-01")
        self.head = self.git("rev-parse", "HEAD")
        self.fake = self.tmp / "gh"
        self.fake.write_text(FAKE_GH)
        self.fake.chmod(0o755)

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def commit(self, name: str, text: str) -> str:
        (self.repo / name).write_text(text)
        self.git("add", name)
        self.git("commit", "-q", "-m", text)
        return self.git("rev-parse", "HEAD")

    def db(
        self,
        *,
        merged: bool = True,
        tree: str | None = None,
        status: str = "ahead",
        runs: list[dict] | None = None,
    ) -> dict:
        h = self.pr_head
        if runs is None:
            runs = [_run("success", "2026-01-01T00:00:00Z")]
        return {
            f"repos/{REPO}/commits/{self.head}/pulls": [
                {
                    "number": 7,
                    "merged_at": "2026-01-01T00:00:00Z" if merged else None,
                    "head": {"sha": h},
                }
            ],
            f"repos/{REPO}/git/commits/{h}": {
                "tree": {"sha": tree or self.pr_tree}
            },
            f"repos/{REPO}/compare/{self.before}...{h}": {"status": status},
            f"repos/{REPO}/commits/{h}/check-runs?check_name=CI passed": {
                "check_runs": runs
            },
        }

    def run_script(
        self, db: dict, before: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        dbfile = self.tmp / "db.json"
        dbfile.write_text(json.dumps(db))
        out = self.tmp / "out"
        out.write_text("")
        env = {
            **os.environ,
            "GH": str(self.fake),
            "FAKE_GH_DB": str(dbfile),
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_OUTPUT": str(out),
        }
        env.pop("CI_CHECK_NAME", None)
        r = subprocess.run(
            ["bash", str(SCRIPT), self.before if before is None else before],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(out.read_text(), r.stdout, "GITHUB_OUTPUT mirrors")
        return r

    def assertTested(self, r, want: bool) -> None:
        self.assertEqual(
            r.stdout.strip(), f"tested={'true' if want else 'false'}", r.stderr
        )

    # The one shape that skips.
    def test_a_rebased_up_to_date_green_pr_is_tested(self) -> None:
        self.assertTested(self.run_script(self.db()), True)

    def test_identical_counts_as_containing_before(self) -> None:
        self.assertTested(self.run_script(self.db(status="identical")), True)

    # Each condition, broken alone.
    def test_main_moved_under_the_pr_is_not_tested(self) -> None:
        """The composition case: the push run is the only test of it."""
        r = self.run_script(self.db(status="diverged"))
        self.assertTested(r, False)
        self.assertIn("does not contain", r.stderr)

    def test_another_tree_is_not_tested(self) -> None:
        r = self.run_script(self.db(tree="0" * 40))
        self.assertTested(r, False)
        self.assertIn("another tree", r.stderr)

    def test_an_unmerged_pr_does_not_count(self) -> None:
        self.assertTested(self.run_script(self.db(merged=False)), False)

    def test_a_red_check_is_not_tested(self) -> None:
        r = self.run_script(self.db(runs=[_run("failure", "2026-01-01")]))
        self.assertTested(r, False)

    def test_the_newest_run_decides(self) -> None:
        """A rerun that went red after a green one is red."""
        runs = [
            _run("success", "2026-01-01T00:00:00Z"),
            _run("failure", "2026-01-02T00:00:00Z"),
        ]
        self.assertTested(self.run_script(self.db(runs=runs)), False)

    def test_a_green_rerun_after_a_red_one_counts(self) -> None:
        runs = [
            _run("failure", "2026-01-01T00:00:00Z"),
            _run("success", "2026-01-02T00:00:00Z"),
        ]
        self.assertTested(self.run_script(self.db(runs=runs)), True)

    def test_another_apps_check_of_the_same_name_does_not_count(self) -> None:
        runs = [_run("success", "2026-01-01T00:00:00Z", app="impostor")]
        self.assertTested(self.run_script(self.db(runs=runs)), False)

    def test_no_check_run_is_not_tested(self) -> None:
        self.assertTested(self.run_script(self.db(runs=[])), False)

    # Fail-safe inputs.
    def test_a_new_branch_push_is_not_tested(self) -> None:
        self.assertTested(self.run_script(self.db(), before="0" * 40), False)

    def test_an_api_error_is_not_tested(self) -> None:
        self.assertTested(self.run_script({}), False)


def _run(conclusion: str, started: str, app: str = "github-actions") -> dict:
    return {
        "conclusion": conclusion,
        "started_at": started,
        "app": {"slug": app},
    }


if __name__ == "__main__":
    unittest.main()
