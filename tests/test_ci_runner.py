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
        self.assertRefused(job("self-hosted"), "can be 'self-hosted'")

    def test_a_label_list_with_self_hosted_is_refused(self) -> None:
        self.assertRefused(job("[self-hosted, macOS, ARM64]"))
        block = job("ubuntu-latest").replace(
            "runs-on: ubuntu-latest",
            "runs-on:\n      - Self-Hosted\n      - macOS",
        )
        self.assertRefused(block)

    def test_labels_no_hosted_image_carries_are_refused(self) -> None:
        # MUST-FIX 1: a runner must carry ALL of a job's labels, and no
        # hosted image carries `macOS`, so these can only run on the Mac.
        self.assertRefused(job("[macOS, ARM64]"), "'macOS'")
        self.assertRefused(job("{labels: [macOS, ARM64]}"), "'macOS'")
        self.assertRefused(job("my-mac"), "not a GitHub-hosted image")
        self.assertRefused(
            job(
                "${{ matrix.os }}",
                "strategy:\n  matrix:\n    os: [ubuntu-latest, macOS]\n",
            ),
            "'macOS'",
        )

    def test_every_documented_hosted_label_passes(self) -> None:
        for label in (
            "ubuntu-latest",
            "ubuntu-24.04",
            "ubuntu-22.04-arm",
            "ubuntu-slim",
            "windows-latest",
            "windows-2025",
            "windows-11-arm",
            "macos-latest",
            "macos-15",
            "macos-26",
            "macos-15-intel",
            "macos-latest-large",
            "macos-15-xlarge",
        ):
            with self.subTest(label=label):
                self.assertPasses(job(label))

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

    def test_workflow_run_and_issue_comment_are_fork_reachable(
        self,
    ) -> None:
        # MUST-FIX 2: both run this repo's workflow on a fork's behalf.
        events_only = (
            "github.event_name != 'pull_request' && "
            "github.event_name != 'pull_request_target'"
        )
        for ev in ("workflow_run", "issue_comment"):
            with self.subTest(ev=ev):
                text = job("self-hosted", f"if: {events_only}\n")
                text = text.replace("[push, pull_request]", ev)
                self.assertRefused(text, f"can be true for {ev}")
        wr = (
            "github.event.workflow_run.head_repository.full_name"
            " == github.repository"
        )
        on_wr = job("self-hosted", f"if: {wr}\n").replace(
            "[push, pull_request]", "workflow_run"
        )
        self.assertPasses(on_wr)
        # A comment on an issue, never on a pull request.
        ic = job("self-hosted", "if: '!github.event.issue.pull_request'\n")
        self.assertPasses(ic.replace("[push, pull_request]", "issue_comment"))

    def test_workflow_run_guards_are_tried_for_every_pr_cause(
        self,
    ) -> None:
        cause = "github.event.workflow_run.event"
        for cond, ok in (
            (f"{cause} != 'pull_request'", False),
            (f"{cause} == 'pull_request_review'", False),
            (f"{cause} == 'pull_request_target'", False),
            (f"{cause} == 'push'", True),
        ):
            with self.subTest(cond=cond):
                text = job("self-hosted", f"if: {cond}\n").replace(
                    "[push, pull_request]", "workflow_run"
                )
                if ok:
                    self.assertPasses(text)
                else:
                    self.assertRefused(text, "workflow_run (via")

    def test_a_null_guard_is_read_not_crashed_on(self) -> None:
        # SHOULD-FIX 3: Python cannot order None; GitHub's `<` can.
        cond = (
            "github.event.pull_request.head.repo != null && "
            f"github.event.pull_request.number < 1 || {GUARD}"
        )
        r = self.gate(job("self-hosted", f"if: {cond}\n"))
        self.assertNotIn("Traceback", r.stdout + r.stderr)
        guarded = f"github.event.pull_request.head.repo != null && {GUARD}"
        self.assertPasses(job("self-hosted", f"if: {guarded}\n"))

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
              matrix: ${{ steps.runners.outputs.matrix }}
            steps:
              - uses: actions/checkout@v7
              - id: legs
                run: make -s plan >> "$GITHUB_OUTPUT"
              - id: runners
                env:
                  LEGS: ${{ steps.legs.outputs.matrix }}
                run: |
                  # Comments and blank lines are allowed.

                  printf 'matrix=%s\\n' "$LEGS" \\
                    | make -s ci-runner CI_RUNNER_WORKFLOW=w.yml \\
                    >> "$GITHUB_OUTPUT"
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
            text.replace("steps.runners.outputs", "steps.other.outputs")
        )
        # The planner's own step is not ci-runner's.
        self.assertRefused(
            text.replace(
                "matrix: ${{ steps.runners.outputs.matrix }}",
                "matrix: ${{ steps.legs.outputs.matrix }}",
            )
        )

    def test_only_a_real_ci_runner_command_counts(self) -> None:
        # NIT 6: a mention in an echo, a heredoc or a comment is not the
        # command, and another writer of $GITHUB_OUTPUT is not ci-runner.
        text = textwrap.dedent(self.PLAN)
        real = (
            "| make -s ci-runner CI_RUNNER_WORKFLOW=w.yml \\\n"
            '            >> "$GITHUB_OUTPUT"'
        )
        self.assertIn(real, text)
        out = '"$GITHUB_OUTPUT"'
        for fake in (
            f'| echo "make -s ci-runner" >> {out}',
            "| echo make ci-runner >> $GITHUB_OUTPUT",
            "| cat >> $GITHUB_OUTPUT <<EOF\n"
            "              make -s ci-runner\n              EOF",
            real + "\n              echo 'matrix={}' >> $GITHUB_OUTPUT",
            "# make -s ci-runner >> $GITHUB_OUTPUT",
            # SHOULD-FIX 3: second writers a deny-list does not see.
            real + "\n              python3 -c 'import os; "
            'open(os.environ["GITHUB_OUTPUT"], "a")\'',
            '| make -s ci-runner >> "$(printenv GITHUB_OUTPUT)"',
            real + '\n              v=GITHUB_; echo m=x >> "${!v}OUTPUT"',
            real + "\n              eval 'echo m=x >> $GITHUB'\"_OUTPUT\"",
            real + " && ./scripts/write-more.sh",
            '| make -s ci-runner X="$(id)" >> ' + out,
        ):
            with self.subTest(fake=fake):
                self.assertRefused(text.replace(real, fake))

    def test_nothing_may_change_the_trusted_steps_world(self) -> None:
        # SHOULD-FIX 3: a startup file, a shell, a directory, a checkout of
        # other code, or an earlier step writing the environment.
        text = textwrap.dedent(self.PLAN)
        env = "          LEGS: ${{ steps.legs.outputs.matrix }}\n"
        step = "      - id: runners\n"
        co = "      - uses: actions/checkout@v7\n"
        for name, fake in (
            ("BASH_ENV", (env, env + "          BASH_ENV: x.sh\n")),
            ("MAKEFLAGS", (env, env + "          MAKEFLAGS: -f x\n")),
            ("shell", (step, step + "        shell: python\n")),
            ("dir", (step, step + "        working-directory: sub\n")),
            ("checkout", (co, co + "        with: {ref: evil}\n")),
            ("action", (co, "      - uses: actions/setup-python@v6\n")),
            (
                "GITHUB_ENV",
                (
                    "        run: make -s plan",
                    "        run: echo P=1 >> $GITHUB_ENV; make -s plan",
                ),
            ),
            (
                "job env",
                (
                    "    outputs:\n",
                    "    env: {BASH_ENV: x.sh}\n    outputs:\n",
                ),
            ),
        ):
            with self.subTest(name=name):
                bad = text.replace(*fake, 1)
                self.assertNotEqual(bad, text)
                self.assertRefused(bad)

    #: A planner that is safe on any event: a plain checkout, then the one
    #: trusted step.
    LONE = """\
        on: @ON@
        jobs:
          plan:
            runs-on: ubuntu-latest
            timeout-minutes: 5
            outputs:
              matrix: ${{ steps.runners.outputs.matrix }}
            steps:
              - uses: actions/checkout@v7
        @PRE@
              - id: runners
                env:
                  LEGS: '{"include": [{"os": "macos-latest"}]}'
                  GITHUB_TOKEN: ${{ github.token }}
                run: @RUN@
          j:
            needs: plan
            runs-on: ${{ matrix.runs_on }}
            timeout-minutes: 5
            strategy:
              matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
        """
    RUN = (
        "printf 'matrix=%s\\n' \"$LEGS\""
        ' | make -s ci-runner >> "$GITHUB_OUTPUT"'
    )

    def lone(self, on: str, run: str = "", pre: str = "") -> str:
        return (
            textwrap.dedent(self.LONE)
            .replace("@ON@", on)
            .replace("@RUN@", run or self.RUN)
            .replace("@PRE@\n", pre)
        )

    def test_no_expression_in_the_trusted_script(self) -> None:
        # MUST-FIX: GitHub pastes ${{ }} into the script before bash runs.
        for on, expr in (
            ("pull_request_target", "github.event.pull_request.title"),
            ("workflow_run", "github.event.workflow_run.head_branch"),
            ("issue_comment", "github.event.comment.body"),
        ):
            with self.subTest(on=on):
                self.assertPasses(self.lone(on))
                bad = self.RUN.replace(
                    "'matrix=%s\\n'", f"'m=${{{{ {expr} }}}}'"
                )
                self.assertNotEqual(bad, self.RUN)
                self.assertRefused(self.lone(on, bad), "can name any runner")

    def test_only_checkouts_before_it_on_fork_driven_events(self) -> None:
        # SHOULD-FIX: an earlier step can fetch the fork's Makefile.
        pre = "      - run: gh pr checkout ${{ github.event.number }}\n"
        pre2 = (
            "      - run: git fetch origin "
            "${{ github.event.workflow_run.head_sha }}"
            " && git checkout FETCH_HEAD\n"
        )
        plain = "      - id: legs\n        run: make -s plan\n"
        for on, step in (
            ("pull_request_target", pre),
            ("workflow_run", pre2),
            ("workflow_call", plain),
            ("issue_comment", plain),
            ("[push, pull_request_review]", plain),
        ):
            with self.subTest(on=on, step=step):
                self.assertRefused(self.lone(on, pre=step))
        # Plain pull_request, push and schedule keep the earlier rule.
        for on in ("[push, pull_request]", "[push, schedule]"):
            with self.subTest(on=on):
                self.assertPasses(self.lone(on, pre=plain))
        # A second plain checkout is still fine anywhere.
        co = "      - uses: actions/checkout@v7\n"
        self.assertPasses(self.lone("pull_request_target", pre=co))

    def test_no_interpreter_loader_or_actions_variables(self) -> None:
        # NIT: PYTHON*, LD_*, DYLD_*, GITHUB_*, RUNNER_* change what runs
        # or what pick reads; GITHUB_TOKEN is the one allowed name.
        base = self.lone("[push, pull_request]")
        self.assertPasses(base)
        tok = "          GITHUB_TOKEN: ${{ github.token }}\n"
        self.assertIn(tok, base)
        for name in (
            "PYTHONPATH",
            "LD_PRELOAD",
            "DYLD_INSERT_LIBRARIES",
            "GITHUB_EVENT_NAME",
            "RUNNER_TEMP",
        ):
            with self.subTest(name=name):
                self.assertRefused(
                    base.replace(tok, tok + f"          {name}: x\n")
                )
        job_env = base.replace(
            "    outputs:\n", "    env: {PYTHONPATH: .}\n    outputs:\n", 1
        )
        self.assertRefused(job_env)

    def test_ci_runner_output_inside_a_matrix_is_refused(self) -> None:
        # MUST-FIX 1(a): only the whole matrix may come from ci-runner.
        text = textwrap.dedent(self.PLAN)
        whole = "      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}"
        self.assertIn(whole, text)
        for inner in (
            "      matrix:\n        include: "
            "${{ fromJSON(needs.plan.outputs.matrix) }}",
            "      matrix:\n        runs_on: "
            "${{ fromJSON(needs.plan.outputs.matrix) }}",
            "      matrix:\n        include:\n"
            "          - ${{ fromJSON(needs.plan.outputs.matrix) }}",
        ):
            with self.subTest(inner=inner):
                self.assertRefused(
                    text.replace(whole, inner), "inside a matrix"
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
    """The org endpoints ``idle`` reads, from in-memory lists.

    Shaped like the real API: a runner's group is known only from
    ``/runner-groups/{id}/runners``, and the entries carry no group field.
    The org-wide ``/actions/runners`` refuses, so a reader that filters it
    on a group id it does not carry cannot pass here.
    """

    def __init__(self, runners: list, groups: "list | None" = None) -> None:
        self.runners = runners
        self.groups = groups or [
            {"id": 1, "visibility": "all", "allows_public_repositories": True}
        ]
        self.repos: "dict[int, list[str]]" = {}
        #: run id -> its jobs, each listed under every status asked for.
        self.runs: "dict[int, list[dict]]" = {}
        self.calls: "list[str]" = []
        self.fail = False
        self.fail_queue = False

    def __call__(self, path: str) -> Any:
        self.calls.append(path)
        if self.fail or (self.fail_queue and path.startswith("/repos/")):
            raise OSError("HTTP 502")
        base, _, query = path.partition("?")
        args = dict(q.split("=") for q in query.split("&"))
        page = int(args["page"])
        if base.endswith("/actions/runs"):
            items = [{"id": i} for i in self.runs]
            key = "workflow_runs"
        elif base.endswith("/jobs"):
            items, key = self.runs[int(base.split("/")[-2])], "jobs"
        elif base.endswith("/runner-groups"):
            items, key = self.groups, "runner_groups"
        elif base.endswith("/repositories"):
            gid = int(base.split("/")[-2])
            items = [{"full_name": r} for r in self.repos.get(gid, [])]
            key = "repositories"
        elif "/runner-groups/" in base and base.endswith("/runners"):
            gid = int(base.split("/")[-2])
            items = [
                {k: v for k, v in r.items() if k != "group"}
                for r in self.runners
                if r["group"] == gid
            ]
            key = "runners"
        else:
            raise AssertionError(f"not an endpoint idle reads: {base}")
        return {key: items[(page - 1) * 100 : page * 100]}


def runner(
    status: str = "online", busy: bool = False, group: int = 1, labels=MAC
) -> dict:
    return {
        "status": status,
        "busy": busy,
        "group": group,  # where FakeApi lists it, never a response field
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
            "GITHUB_TOKEN": "g",
        }
        self.api = FakeApi([runner()])

    def run_pick(
        self,
        lines: "list[str] | None" = None,
        keys=("runs_on", "os"),
        workflow: str = "",
    ) -> "tuple[list[Any], list[str]]":
        out, log = cr.pick(
            lines or ["matrix=" + json.dumps(MATRIX)],
            keys,
            self.env,
            self.api,
            workflow=workflow,
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
        self.assertIn("a pull_request from x/repo", log[0])
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

    def event(self, name: str, payload: dict) -> None:
        self.env["GITHUB_EVENT_NAME"] = name
        f = self.tmp / f"{name}.json"
        f.write_text(json.dumps(payload))
        self.env["GITHUB_EVENT_PATH"] = str(f)

    def test_a_fork_workflow_run_stays_hosted(self) -> None:
        for head in ({"full_name": "x/repo"}, None):
            with self.subTest(head=head):
                self.event(
                    "workflow_run", {"workflow_run": {"head_repository": head}}
                )
                legs, log = self.run_pick()
                self.assertEqual(legs, self.hosted())
                self.assertIn("a workflow_run from", log[0])
        self.event(
            "workflow_run",
            {"workflow_run": {"head_repository": {"full_name": "org/repo"}}},
        )
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_a_comment_on_a_pull_request_stays_hosted(self) -> None:
        self.event("issue_comment", {"issue": {"pull_request": {"url": "u"}}})
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn("a comment on a pull request", log[0])
        self.event("issue_comment", {"issue": {"number": 1}})
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_queued_jobs_for_the_pool_are_counted_first(self) -> None:
        # SHOULD-FIX 5: one idle Mac, one job of this repo already queued
        # for it: nothing left for this run.
        self.api.runs = {7: [{"status": "queued", "labels": MAC}]}
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn(
            "macOS ARM64: 1 job(s) already queued for 1 idle runner(s)", log
        )
        self.api.runners = [runner(), runner()]
        self.assertEqual(self.run_pick()[0][1:], [MAC, "macos-latest"])

    def test_running_or_other_jobs_do_not_count(self) -> None:
        self.api.runs = {
            7: [
                {"status": "in_progress", "labels": MAC},
                {"status": "completed", "labels": MAC},
                {"status": "queued", "labels": ["ubuntu-latest"]},
            ]
        }
        self.assertEqual(self.run_pick()[0][1], MAC)

    def test_no_queue_token_or_a_queue_error_stays_hosted(self) -> None:
        self.env["GITHUB_TOKEN"] = ""
        legs, log = self.run_pick()
        self.assertEqual(legs, self.hosted())
        self.assertIn("no GITHUB_TOKEN", log[0])
        self.env["GITHUB_TOKEN"] = "g"
        self.api.fail_queue = True
        self.assertEqual(self.run_pick()[0], self.hosted())

    def test_a_group_restricted_to_workflows_matches_this_one(self) -> None:
        # SHOULD-FIX 4: "Selected workflows", pinned to main.
        wf = "org/repo/.github/workflows/ci.yml"
        g = {
            "id": 1,
            "visibility": "all",
            "allows_public_repositories": True,
            "restricted_to_workflows": True,
        }
        for listed, ref, ok in (
            (f"{wf}@refs/heads/main", "refs/heads/main", True),
            (f"{wf}@main", "refs/heads/main", True),
            (f"{wf}@main", "refs/pull/3/merge", False),
            (
                "org/repo/.github/workflows/other.yml@main",
                "refs/heads/main",
                False,
            ),
            # NIT 4: no wildcards; GitHub documents none.
            ("org/repo/.github/workflows/*@main", "refs/heads/main", False),
        ):
            with self.subTest(listed=listed, ref=ref):
                self.api.groups = [dict(g, selected_workflows=[listed])]
                self.env["GITHUB_WORKFLOW_REF"] = f"{wf}@{ref}"
                got = self.run_pick(workflow=".github/workflows/ci.yml")[0][1]
                self.assertEqual(got, MAC if ok else "macos-latest")
        self.api.groups = [dict(g, selected_workflows=[f"{wf}@main"])]
        self.env["GITHUB_WORKFLOW_REF"] = f"{wf}@refs/heads/main"
        # No --workflow: a restricted group never counts.
        self.assertEqual(self.run_pick()[0][1], "macos-latest")
        # A reusable workflow's run: the ref names its caller.
        got = self.run_pick(workflow=".github/workflows/artifact.yml")[0][1]
        self.assertEqual(got, "macos-latest")
        self.env.pop("GITHUB_WORKFLOW_REF")
        got = self.run_pick(workflow=".github/workflows/ci.yml")[0][1]
        self.assertEqual(got, "macos-latest")

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
            ["tag=x", "matrix=", "ref=v1.2"], ("os",), self.env, self.api
        )
        self.assertEqual(out, ["tag=x", "matrix=", "ref=v1.2"])

    def test_input_that_is_not_a_plan_is_refused(self) -> None:
        bad = [
            [],
            ['m={"os": ["macos-latest"]}'],
            ['m={"include": [{"os": "self-hosted"}]}'],
            ['m={"include": [{"python": "3.12"}]}'],
            # MUST-FIX 1: any label no hosted image carries.
            ['m={"include": [{"os": "macOS"}]}'],
            ['m={"include": [{"os": "my-mac"}]}'],
            # NIT 6: a multi-line output would pass through unread.
            ["m<<EOF", '{"include": [{"os": "macOS"}]}', "EOF"],
            ["just text"],
            # MUST-FIX 1(b): JSON a job could read with fromJSON.
            ['m=[{"runs_on": "self-hosted"}]'],
            ['m="self-hosted"'],
            ["m=[1]"],
            ["m=3"],
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
            "GITHUB_TOKEN": "repo-token",
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
        self.assertEqual(
            set(_Handler.auth), {"Bearer sekret", "Bearer repo-token"}
        )

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
