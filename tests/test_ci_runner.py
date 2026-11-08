"""Behaviour of scripts/ci-runner.py: ``self-hosted-check`` and ``ci-runner``.

The gate's cases are workflow files a fork's pull request could, or could
not, run on a self-hosted runner, each checked through ``make
self-hosted-check`` in a scratch adopter (the wiring is part of what is
tested) or through ``check`` directly. The picker's cases mock the GitHub
API with a fake ``fetch`` for every branch, and once with a real local HTTP
server, so the urllib path and ``make ci-runner`` run too. Stdlib only,
like the script: ``python3 -m unittest discover -s tests``.
"""

from __future__ import annotations

import doctest
import http.server
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import threading
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ci-runner.py"

_spec = importlib.util.spec_from_file_location("ci_runner", SCRIPT)
assert _spec is not None and _spec.loader is not None
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)

MAC = ["self-hosted", "macOS", "ARM64"]
GUARD = "github.event.pull_request.head.repo.full_name == github.repository"


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    """Run the script's doctests with the rest of the suite."""
    tests.addTests(doctest.DocTestSuite(cr))
    return tests


def job(runs_on: str, extra: str = "") -> str:
    return textwrap.dedent(
        f"""\
        on: [push, pull_request]
        jobs:
          j:
            runs-on: {runs_on}
            timeout-minutes: 5
        """
    ) + textwrap.indent(textwrap.dedent(extra), "    ")


class Adopter(unittest.TestCase):
    """A scratch repo that includes standard.mk, with workflows to check."""

    def setUp(self) -> None:
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        shutil.copy(ROOT / "standard.mk", self.dir)
        (self.dir / "scripts").mkdir()
        shutil.copy(SCRIPT, self.dir / "scripts")
        (self.dir / "Makefile").write_text(
            "TEST_CMD = @true\nTEST_FAST_CMD = @true\nCLEAN_PATHS = d/\n"
            "include standard.mk\n"
        )
        self.wf = self.dir / ".github" / "workflows"
        self.wf.mkdir(parents=True)

    def make(self, *args: str, stdin: str = "", **env: str) -> Any:
        return subprocess.run(
            ["make", "-s", "-C", str(self.dir), *args],
            input=stdin,
            capture_output=True,
            text=True,
            env={**os.environ, **env},
        )

    def gate(self, text: str, name: str = "w.yml") -> Any:
        (self.wf / name).write_text(text)
        return self.make("self-hosted-check")

    def assertRefused(self, text: str, why: str = "") -> None:
        r = self.gate(text)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("w.yml: j:", r.stdout)
        self.assertIn(why, r.stdout)

    def assertPasses(self, text: str) -> None:
        r = self.gate(text)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("none lets a fork", r.stdout)


class Gate(Adopter):
    def test_no_workflows_is_inert(self) -> None:
        shutil.rmtree(self.dir / ".github")
        r = self.make("self-hosted-check")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("nothing to check", r.stdout)

    def test_lint_runs_it(self) -> None:
        # Its execution home: CI runs `make lint`, so lint must reach it.
        r = self.make("-n", "lint")
        self.assertIn(
            "python3 scripts/ci-runner.py check .github/workflows",
            r.stdout.splitlines(),
        )

    def test_hosted_jobs_pass(self) -> None:
        self.assertPasses(job("ubuntu-latest"))
        self.assertPasses(job("[macos-latest]"))

    def test_a_literal_self_hosted_job_is_refused(self) -> None:
        self.assertRefused(job("self-hosted"), "runs-on can be self-hosted")

    def test_a_label_list_with_self_hosted_is_refused(self) -> None:
        self.assertRefused(job("[self-hosted, macOS, ARM64]"))
        block = job("ubuntu-latest").replace(
            "runs-on: ubuntu-latest",
            "runs-on:\n      - Self-Hosted\n      - macOS",
        )
        self.assertRefused(block)

    def test_a_runner_group_is_refused(self) -> None:
        self.assertRefused(job("{group: mac}"), "runner group")

    def test_the_fork_guard_passes(self) -> None:
        self.assertPasses(job("[self-hosted, macOS]", f"if: {GUARD}\n"))
        self.assertPasses(job("self-hosted", f"if: ${{{{ {GUARD} }}}}\n"))
        # Either side, any case, under an &&.
        rev = "always() && github.repository == " + (
            "github.event.pull_request.head.repo.full_name"
        )
        self.assertPasses(job("self-hosted", f"if: {rev}\n"))

    def test_the_event_disjunction_passes_for_the_events_it_names(
        self,
    ) -> None:
        cond = (
            "github.event_name != 'pull_request' && "
            f"github.event_name != 'pull_request_target' || {GUARD}"
        )
        self.assertPasses(job("self-hosted", f"if: {cond}\n"))
        on_target = job("self-hosted", f"if: {cond}\n").replace(
            "[push, pull_request]", "[push, pull_request_target]"
        )
        self.assertPasses(on_target)
        # Naming pull_request only: a pull_request_target run gets through.
        half = f"github.event_name != 'pull_request' || {GUARD}"
        self.assertRefused(
            on_target.replace(cond, half), "pull_request_target from a fork"
        )

    def test_a_guard_true_for_a_deleted_fork_is_refused(self) -> None:
        # null == false is TRUE in GitHub's loose equality.
        cond = "github.event.pull_request.head.repo.fork == false"
        self.assertRefused(
            job("self-hosted", f"if: {cond}\n"), "from a deleted fork"
        )

    def test_a_guard_that_is_only_unknown_is_refused(self) -> None:
        for cond in (
            "needs.plan.outputs.ok == 'true'",
            f"{GUARD} || success()",
            "github.actor == 'owner'",
        ):
            with self.subTest(cond=cond):
                self.assertRefused(job("self-hosted", f"if: {cond}\n"))

    def test_text_around_an_expression_is_always_true(self) -> None:
        self.assertRefused(
            job("self-hosted", f"if: ${{{{ {GUARD} }}}} && true\n"),
            "always true",
        )

    def test_a_workflow_no_pull_request_starts_may_use_one(self) -> None:
        text = job("self-hosted").replace(
            "[push, pull_request]", "[push, schedule]"
        )
        self.assertPasses(text)

    def test_a_reusable_workflow_runs_on_its_callers_event(self) -> None:
        text = job("self-hosted").replace(
            "[push, pull_request]", "workflow_call"
        )
        self.assertRefused(text)

    def test_a_static_matrix_is_resolved(self) -> None:
        hosted = """\
            strategy:
              matrix:
                os: [ubuntu-latest, macos-latest]
                include:
                  - { os: windows-latest, arch: { runner: windows-latest } }
            """
        self.assertPasses(job("${{ matrix.os }}", hosted))
        self.assertPasses(job("${{ matrix.arch.runner }}", hosted))
        self.assertRefused(
            job(
                "${{ matrix.os }}",
                hosted.replace("windows-latest,", "self-hosted,"),
            )
        )
        nested = hosted.replace(
            "{ runner: windows-latest }", "{ runner: [self-hosted, macOS] }"
        )
        self.assertRefused(job("${{ matrix.arch.runner }}", nested))

    def test_fromjson_of_literals_is_resolved(self) -> None:
        expr = (
            "${{ fromJSON(inputs.quick && '[\"ubuntu-latest\"]' || "
            '\'["ubuntu-latest", "macos-latest"]\') }}'
        )
        m = f"strategy:\n  matrix:\n    os: {expr}\n"
        self.assertPasses(job("${{ matrix.os }}", m))
        sabotaged = m.replace("'[\"ubuntu-latest\"]'", "'[\"self-hosted\"]'")
        self.assertNotEqual(sabotaged, m)
        self.assertRefused(job("${{ matrix.os }}", sabotaged))
        cond = (
            "${{ (matrix.os == 'ubuntu-latest' && inputs.x == '3.9') && "
            "'ubuntu-24.04' || matrix.os }}"
        )
        self.assertPasses(job(cond, m))

    def test_an_input_or_variable_is_refused(self) -> None:
        for src in ("inputs.runner", "vars.RUNNER", "github.event.inputs.r"):
            with self.subTest(src=src):
                self.assertRefused(
                    job(f"${{{{ {src} }}}}"), "can name any runner"
                )

    PLAN = """\
        on: [push, pull_request]
        jobs:
          plan:
            runs-on: ubuntu-latest
            timeout-minutes: 5
            outputs:
              matrix: ${{ steps.legs.outputs.matrix }}
            steps:
              - id: legs
                run: |
                  legs=$(make -s plan)
                  printf '%s\\n' "$legs" | make -s ci-runner >> "$OUT"
          j:
            needs: plan
            runs-on: ${{ matrix.runs_on }}
            timeout-minutes: 5
            strategy:
              matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
        """

    def test_runs_on_from_ci_runner_passes_unguarded(self) -> None:
        self.assertPasses(textwrap.dedent(self.PLAN))

    def test_another_planner_is_refused(self) -> None:
        text = textwrap.dedent(self.PLAN)
        self.assertRefused(
            text.replace("make -s ci-runner", "cat"), "can name any runner"
        )
        self.assertRefused(
            text.replace("make -s ci-runner", "make -s ci-runner-x")
        )
        self.assertRefused(
            text.replace("steps.legs.outputs", "steps.other.outputs")
        )

    def test_only_runs_on_of_a_ci_runner_matrix_is_trusted(self) -> None:
        text = textwrap.dedent(self.PLAN).replace(
            "runs-on: ${{ matrix.runs_on }}", "runs-on: ${{ matrix.os }}"
        )
        self.assertRefused(text, "only runs_on is decided by ci-runner")

    def test_a_file_it_cannot_read_is_refused(self) -> None:
        r = self.gate("x: &a 1\njobs:\n  j:\n    runs-on: *a\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("cannot read", r.stdout)
        self.assertIn("w.yml", r.stdout)

    def test_a_walk_that_finds_no_job_is_refused(self) -> None:
        r = self.gate("on: push\njobs: {}\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no job was parsed", r.stdout)

    def test_canonicals_own_workflows_pass(self) -> None:
        jobs, problems, broken = cr.check(
            [
                str(ROOT / ".github" / "workflows"),
                str(ROOT / "github" / "workflows"),
            ]
        )
        self.assertEqual((problems, broken), ([], []))
        self.assertGreater(jobs, 0)


class YamlSubset(unittest.TestCase):
    def test_the_shapes_workflows_use(self) -> None:
        text = textwrap.dedent(
            """\
            "on":
              push: {branches: [main]}   # comment
            jobs:
              a:
                if: >-
                  x &&
                  y
                steps:
                - run: |
                    echo "a: b" # kept
                    echo 'c'
                  name: 'it''s'
                - uses: x@v1
                - >-
                  folded
                  line
                env: {A: "1, 2", B: [p,
                  q]}
            """
        )
        got = cr.load_yaml(text)
        self.assertEqual(got["on"], {"push": {"branches": ["main"]}})
        a = got["jobs"]["a"]
        self.assertEqual(a["if"], "x && y")
        self.assertEqual(
            a["steps"][0]["run"], "echo \"a: b\" # kept\necho 'c'\n"
        )
        self.assertEqual(a["steps"][0]["name"], "it's")
        self.assertEqual(a["steps"][2], "folded line")
        self.assertEqual(a["env"], {"A": "1, 2", "B": ["p", "q"]})


def pr_event(tmp: pathlib.Path, head: "str | None", private: bool) -> str:
    repo = {"full_name": head} if head else None
    ev = {
        "pull_request": {"head": {"repo": repo}},
        "repository": {"private": private},
    }
    p = tmp / "event.json"
    p.write_text(json.dumps(ev))
    return str(p)


class FakeApi:
    """The three org endpoints ``idle`` reads, from in-memory lists."""

    def __init__(self, runners: list, groups: "list | None" = None) -> None:
        self.runners = runners
        self.groups = groups or [
            {"id": 1, "visibility": "all", "allows_public_repositories": True}
        ]
        self.repos: "dict[int, list[str]]" = {}
        self.calls: "list[str]" = []
        self.fail = False

    def __call__(self, path: str) -> Any:
        self.calls.append(path)
        if self.fail:
            raise OSError("HTTP 502")
        base, _, query = path.partition("?")
        page = int(dict(q.split("=") for q in query.split("&"))["page"])
        if base.endswith("/runner-groups"):
            items, key = self.groups, "runner_groups"
        elif base.endswith("/repositories"):
            gid = int(base.split("/")[-2])
            items = [{"full_name": r} for r in self.repos.get(gid, [])]
            key = "repositories"
        else:
            items, key = self.runners, "runners"
        return {key: items[(page - 1) * 100 : page * 100]}


def runner(
    status: str = "online", busy: bool = False, group: int = 1, labels=MAC
) -> dict:
    return {
        "status": status,
        "busy": busy,
        "runner_group_id": group,
        "labels": [{"name": x} for x in labels],
    }


MATRIX = {
    "include": [
        {"os": "ubuntu-latest", "python-version": "3.12"},
        {"os": "macos-latest", "python-version": "3.10"},
        {"os": "macos-latest", "python-version": "3.14"},
    ]
}


class Pick(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.env = {
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": "org/repo",
            "GITHUB_EVENT_PATH": pr_event(self.tmp, None, False),
            "JB_SELF_HOSTED_MACOS": "true",
            "JB_RUNNER_READ_TOKEN": "t",
        }
        self.api = FakeApi([runner()])

    def run_pick(
        self, lines: "list[str] | None" = None, keys=("runs_on", "os")
    ) -> "tuple[list[Any], list[str]]":
        out, log = cr.pick(
            lines or ["matrix=" + json.dumps(MATRIX)], keys, self.env, self.api
        )
        legs = []
        for line in out:
            name, _, value = line.partition("=")
            if value.startswith("{"):
                legs += [x["runs_on"] for x in json.loads(value)["include"]]
        return legs, log

    def hosted(self) -> list:
        return ["ubuntu-latest", "macos-latest", "macos-latest"]

    def test_one_idle_runner_takes_one_leg(self) -> None:
        legs, log = self.run_pick()
        self.assertEqual(legs, ["ubuntu-latest", MAC, "macos-latest"])
        self.assertIn("macOS ARM64: 1 of 2 leg(s) self-hosted", log)

    def test_as_many_legs_as_idle_runners(self) -> None:
        self.api.runners = [runner(), runner(), runner()]
        legs, _ = self.run_pick()
        self.assertEqual(legs, ["ubuntu-latest", MAC, MAC])

    def test_allocation_runs_across_lines_in_order(self) -> None:
        one = {"include": [{"os": "macos-latest"}]}
        legs, _ = self.run_pick(
            ["first=" + json.dumps(one), "second=" + json.dumps(one)]
        )
        self.assertEqual(legs, [MAC, "macos-latest"])

    def test_a_fork_pr_stays_hosted_without_asking(self) -> None:
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        self.env["GITHUB_EVENT_PATH"] = pr_event(self.tmp, "x/repo", False)
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn("a pull request from x/repo", log[0])
        self.assertEqual(self.api.calls, [])

    def test_a_deleted_fork_counts_as_a_fork(self) -> None:
        for event in ("pull_request_target", "pull_request_review"):
            with self.subTest(event=event):
                self.env["GITHUB_EVENT_NAME"] = event
                self.env["GITHUB_EVENT_PATH"] = pr_event(self.tmp, None, False)
                self.assertEqual(self.run_pick()[0], self.hosted())

    def test_an_unreadable_event_stays_hosted(self) -> None:
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        self.env["GITHUB_EVENT_PATH"] = str(self.tmp / "missing.json")
        self.assertEqual(self.run_pick()[0], self.hosted())

    def test_a_same_repo_pr_may_use_it(self) -> None:
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        self.env["GITHUB_EVENT_PATH"] = pr_event(self.tmp, "Org/Repo", False)
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_outside_actions_stays_hosted(self) -> None:
        del self.env["GITHUB_EVENT_NAME"]
        self.assertEqual(self.run_pick()[0], self.hosted())

    def test_no_opt_in_stays_hosted(self) -> None:
        for v in (None, "", "false", "1"):
            with self.subTest(v=v):
                self.env.pop("JB_SELF_HOSTED_MACOS", None)
                if v is not None:
                    self.env["JB_SELF_HOSTED_MACOS"] = v
                legs, log = self.run_pick()
                self.assertEqual(legs, self.hosted())
                self.assertIn("JB_SELF_HOSTED_MACOS is not 'true'", log[0])

    def test_no_token_stays_hosted_without_asking(self) -> None:
        self.env["JB_RUNNER_READ_TOKEN"] = ""
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn("no JB_RUNNER_READ_TOKEN", log[0])
        self.assertEqual(self.api.calls, [])

    def test_an_api_error_stays_hosted(self) -> None:
        self.api.fail = True
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn("runner API: HTTP 502", log[0])

    def test_busy_offline_or_other_runners_do_not_count(self) -> None:
        for r in (
            runner(busy=True),
            runner(status="offline"),
            runner(labels=["self-hosted", "Linux", "ARM64"]),
            runner(labels=["self-hosted", "macOS", "X64"]),
        ):
            with self.subTest(r=r):
                self.api.runners = [r]
                self.assertEqual(self.run_pick()[0], self.hosted())

    def test_a_group_this_repo_cannot_use_does_not_count(self) -> None:
        cases = [
            {"id": 1, "visibility": "all"},  # public repo, not allowed
            {
                "id": 1,
                "visibility": "private",
                "allows_public_repositories": True,
            },
            {
                "id": 1,
                "visibility": "selected",
                "allows_public_repositories": True,
            },
            {
                "id": 1,
                "visibility": "all",
                "allows_public_repositories": True,
                "restricted_to_workflows": True,
            },
            {"id": 2, "visibility": "all", "allows_public_repositories": True},
        ]
        for g in cases:
            with self.subTest(g=g):
                self.api.groups = [g]
                self.assertEqual(self.run_pick()[0], self.hosted())

    def test_a_group_this_repo_can_use_counts(self) -> None:
        self.api.groups = [
            {
                "id": 1,
                "visibility": "selected",
                "allows_public_repositories": True,
            }
        ]
        self.api.repos = {1: ["ORG/repo"]}
        self.assertEqual(self.run_pick()[0][1], MAC)
        # A private repository needs no public-repository access.
        self.api.groups = [{"id": 1, "visibility": "private"}]
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        self.env["GITHUB_EVENT_PATH"] = pr_event(self.tmp, "org/repo", True)
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_every_page_of_runners_is_read(self) -> None:
        self.api.runners = [runner(busy=True)] * 100 + [runner()]
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_the_first_key_a_leg_has_names_its_label(self) -> None:
        m = {
            "include": [
                {"os": "ubuntu-latest", "runs_on": "macos-14"},
                {"os": "macos-latest"},
            ]
        }
        legs, _ = self.run_pick(["m=" + json.dumps(m)])
        self.assertEqual(legs, [MAC, "macos-latest"])

    def test_x64_mac_labels_stay_hosted(self) -> None:
        m = {
            "include": [
                {"os": x}
                for x in ("macos-13", "macos-15-intel", "macos-14-large")
            ]
        }
        legs, _ = self.run_pick(["m=" + json.dumps(m)])
        self.assertEqual(
            legs, ["macos-13", "macos-15-intel", "macos-14-large"]
        )

    def test_other_lines_pass_through(self) -> None:
        out, _ = cr.pick(
            ["tag=x", "matrix=", "n=[1]"], ("os",), self.env, self.api
        )
        self.assertEqual(out, ["tag=x", "matrix=", "n=[1]"])

    def test_input_that_is_not_a_plan_is_refused(self) -> None:
        bad = [
            [],
            ['m={"os": ["macos-latest"]}'],
            ['m={"include": [{"os": "self-hosted"}]}'],
            ['m={"include": [{"python": "3.12"}]}'],
        ]
        for lines in bad:
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                cr.pick(lines, ("os",), self.env, self.api)


class _Handler(http.server.BaseHTTPRequestHandler):
    api: FakeApi
    auth: "list[str]" = []

    def do_GET(self) -> None:  # noqa: N802
        self.auth.append(self.headers.get("Authorization", ""))
        body = json.dumps(self.api(self.path)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_: Any) -> None:
        pass


class MakeCiRunner(Adopter):
    """``make ci-runner`` end to end, against a local API server."""

    def serve(self, api: FakeApi) -> str:
        _Handler.api, _Handler.auth = api, []
        srv = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return f"http://127.0.0.1:{srv.server_address[1]}"

    def env(self, **kw: str) -> "dict[str, str]":
        ev = self.dir / "event.json"
        ev.write_text(json.dumps({"repository": {"private": False}}))
        return {
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REPOSITORY": "org/repo",
            "GITHUB_EVENT_PATH": str(ev),
            "JB_SELF_HOSTED_MACOS": "true",
            "JB_RUNNER_READ_TOKEN": "sekret",
            **kw,
        }

    def test_make_ci_runner_routes_a_leg_over_http(self) -> None:
        url = self.serve(FakeApi([runner()]))
        r = self.make(
            "ci-runner",
            stdin="tag=v1\nmatrix=" + json.dumps(MATRIX) + "\n",
            **self.env(GITHUB_API_URL=url),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        tag, matrix = r.stdout.splitlines()
        self.assertEqual(tag, "tag=v1")
        legs = json.loads(matrix.partition("=")[2])["include"]
        self.assertEqual([x["runs_on"] for x in legs][1], MAC)
        self.assertEqual(set(_Handler.auth), {"Bearer sekret"})

    def test_an_unreachable_api_stays_hosted(self) -> None:
        r = self.make(
            "ci-runner",
            stdin="matrix=" + json.dumps(MATRIX) + "\n",
            **self.env(GITHUB_API_URL="http://127.0.0.1:9"),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        legs = json.loads(r.stdout.partition("=")[2])["include"]
        self.assertEqual([x["runs_on"] for x in legs][1], "macos-latest")
        self.assertIn("runner API", r.stderr)

    def test_no_input_fails(self) -> None:
        r = self.make("ci-runner", stdin="", **self.env())
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no planner output", r.stderr)


if __name__ == "__main__":
    unittest.main()
