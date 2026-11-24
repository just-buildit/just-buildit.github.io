"""standard.mk's ``ci-changes-wiring-check`` on the aggregator's name and if.

The required check ``CI_CHECK_NAME`` must exist only where the full gate
ran (just-buildit.github.io#241). The aggregator job may be named it
literally, with no ``if:`` or ``if: always()``, or by an expression of the
single-branch shape ``<cond> && 'CI passed' || ... || '<other>'``; an
expression that can yield the name off the gate, and a literal whose
``if:`` can be false (a SKIPPED required check reads as passing), are
refused.

Each test builds a throwaway repo -- this ``standard.mk``, the vendored
``scripts/ci-gate-name.py``, a minimal Makefile and a ``ci.yml`` -- and runs
the target, so what is tested is the gate an adopter runs. The script's
doctests run here too. Stdlib only; needs GNU make.
"""

from __future__ import annotations

import doctest
import importlib.util
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ci-gate-name.py"

#: doppler #3302's aggregator name, verbatim.
EXPRESSION = (
    "\"${{ needs.scope.outputs.scope == 'full' && 'CI passed' || "
    "needs.scope.outputs.scope == 'minimal' && "
    "'CI passed (push, minimal set)' || "
    "'CI passed (skipped: the PR run is the gate)' }}\""
)


def load_tests(loader, tests, ignore):
    spec = importlib.util.spec_from_file_location("ci_gate_name", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    tests.addTests(doctest.DocTestSuite(mod))
    return tests


def workflow(name: str, cond: str | None) -> str:
    """A wired ci.yml whose aggregator has this name and if: (None: none)."""
    agg = f"    name: {name}\n    needs: [changes, test]\n"
    if cond is not None:
        agg += f"    if: {cond}\n"
    return (
        textwrap.dedent(
            """\
            on: [push, pull_request]
            jobs:
              changes:
                uses: ./.github/workflows/changes.yml
              test:
                needs: changes
                if: needs.changes.outputs.src == 'true'
                runs-on: ubuntu-latest
              ci-passed:
            """
        )
        + agg
        + "    runs-on: ubuntu-latest\n"
    )


class GateName(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(ROOT / "standard.mk", self.tmp / "standard.mk")
        (self.tmp / "scripts").mkdir()
        shutil.copy(SCRIPT, self.tmp / "scripts" / SCRIPT.name)
        (self.tmp / "Makefile").write_text(
            "HAS_RELEASE = 1\nBUMP_VERSION_CMD = true\n"
            "RELEASE_WATCH_CMD = true\nVERSION_PROBES = v|echo 1\n"
            "TEST_CMD = @echo t\nTEST_FAST_CMD = @echo t\n"
            "CLEAN_PATHS = d/\ninclude standard.mk\n"
        )
        (self.tmp / ".github" / "workflows").mkdir(parents=True)

    def gate(self, name: str, cond: str | None):
        (self.tmp / ".github" / "workflows" / "ci.yml").write_text(
            workflow(name, cond)
        )
        env = {k: v for k, v in os.environ.items() if k != "MAKEFLAGS"}
        return subprocess.run(
            ["make", "-s", "--no-print-directory", "-C", str(self.tmp),
             "ci-changes-wiring-check", "CI_CHECK_NAME=CI passed"],
            env=env, capture_output=True, text=True, timeout=120,
        )

    def accepts(self, name: str, cond: str | None) -> None:
        r = self.gate(name, cond)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("3 job(s)", r.stdout)

    def refuses(self, name: str, cond: str | None, why: str) -> None:
        r = self.gate(name, cond)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(why, r.stdout + r.stderr)

    # -- expressions ------------------------------------------------------

    def test_accepts_the_issue_expression(self) -> None:
        self.accepts(EXPRESSION, "always()")

    def test_refuses_the_minimal_branch_returning_the_name(self) -> None:
        self.refuses(
            EXPRESSION.replace(" (push, minimal set)", ""),
            "always()",
            "branch 2 yields 'CI passed' off the gate: "
            "needs.scope.outputs.scope == 'minimal' && 'CI passed'",
        )

    def test_refuses_the_name_as_the_fallback(self) -> None:
        self.refuses(
            "\"${{ needs.s.outputs.scope == 'full' && 'CI passed (full)'"
            " || 'CI passed' }}\"",
            "always()",
            "the fallback yields 'CI passed' off the gate",
        )

    def test_refuses_the_name_unconditionally(self) -> None:
        self.refuses(
            "\"${{ 'CI passed' }}\"",
            "always()",
            "yields 'CI passed' unconditionally",
        )

    def test_refuses_parentheses(self) -> None:
        self.refuses(
            "\"${{ (a || b) && 'CI passed' || 'x' }}\"",
            "always()",
            "unsupported '('",
        )

    def test_refuses_an_expression_under_a_conditional_if(self) -> None:
        self.refuses(EXPRESSION, "github.event_name == 'push'",
                     "its if: is not always()")

    def test_a_longer_name_off_the_gate_is_not_the_name(self) -> None:
        # Whole-value comparison: 'CI passed (push, minimal set)' contains
        # 'CI passed' and must not count as it.
        self.accepts(
            "\"${{ needs.s.outputs.scope == 'full' && 'CI passed'"
            " || 'CI passed (push, minimal set)' }}\"",
            "always()",
        )

    def test_a_case_or_space_variant_off_the_gate_is_the_name(self) -> None:
        # Failing closed: a value equal to the name but for case or its
        # ends is treated as the name, so off the gate it is refused.
        for v in ("ci passed", " CI passed "):
            self.refuses(
                "\"${{ needs.s.outputs.scope == 'full' && 'CI passed'"
                f" || '{v}' }}}}\"",
                "always()",
                "the fallback yields 'CI passed' off the gate",
            )

    def test_refuses_a_backslash_escape_in_a_double_quoted_name(self) -> None:
        # YAML decodes "\x20" to a space, so branch 2 below IS 'CI passed'.
        # Nothing may compare the undecoded text. The awk walk refuses any
        # escaped double-quoted name first; the script refuses it again
        # (its doctests), so either refusal satisfies this test.
        self.refuses(
            "\"${{ needs.s.outputs.scope == 'full' && 'CI passed'"
            " || needs.s.outputs.scope == 'min' && 'CI\\x20passed'"
            " || 'z' }}\"",
            "always()",
            "backslash escape",
        )

    def test_refuses_a_backslash_escape_in_a_double_quoted_if(self) -> None:
        self.refuses(
            "CI passed",
            "\"${{ alw\\x61ys() }}\"",
            "a backslash escape in a double-quoted value is not supported",
        )

    def test_a_hash_inside_quotes_is_not_a_comment(self) -> None:
        # ` #` inside a quoted scalar is text, not a YAML comment: cutting
        # there left an unterminated string and refused a valid name.
        self.accepts(
            "\"${{ needs.s.outputs.scope == 'full' && 'CI passed'"
            " || 'CI passed #2' }}\"  # the gate",
            "always()  # the aggregator always runs",
        )

    # -- literal names ----------------------------------------------------

    def test_refuses_a_literal_with_a_conditional_if(self) -> None:
        self.refuses(
            "CI passed",
            "github.event_name == 'pull_request'",
            "its if: is not always(): github.event_name == 'pull_request'",
        )

    def test_accepts_a_literal_with_always(self) -> None:
        self.accepts("CI passed", "always()")

    def test_accepts_a_literal_with_wrapped_always(self) -> None:
        self.accepts("CI passed", "${{ always() }}")
        self.accepts("CI passed", "\"${{always( )}}\"")

    def test_refuses_a_literal_with_no_if(self) -> None:
        # The aggregator needs: the matrix, so with no if: GitHub ANDs in
        # success() and SKIPS it when a need fails -- a skipped required
        # check counts as passing.
        self.refuses("CI passed", None, "it has no if: -- with needs:")

    def test_refuses_a_literal_in_another_case(self) -> None:
        self.refuses("ci passed", "always()", "but for case or whitespace")

    def test_refuses_two_jobs_that_can_carry_the_name(self) -> None:
        # A second job of the required name reports a second check of it on
        # the same commit: the hazard this gate exists for, by another route.
        r = self.gate(
            "CI passed\n    needs: [changes]\n  again:\n    name: CI passed",
            None,
        )
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("more than one job", r.stdout)
        self.assertIn("ci-passed again", r.stdout)

    def test_refuses_an_escaped_name_on_another_job(self) -> None:
        # "CI\x20passed" is 'CI passed' once YAML decodes it: a second
        # aggregator no substring match would see.
        r = self.gate(
            "CI passed\n    needs: [changes]\n  again:\n"
            "    name: \"CI\\x20passed\"",
            "always()",
        )
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("holds a backslash escape", r.stdout)
        self.assertIn("  again", r.stdout)

    def test_a_literal_longer_name_is_no_aggregator(self) -> None:
        self.refuses("CI passed (push, minimal set)", "always()",
                     "no job named 'CI passed'")


if __name__ == "__main__":
    unittest.main()
