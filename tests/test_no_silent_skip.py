"""No test here may skip, and a missing jq fails the tests that need it.

unittest reports a skip as OK. test_ci_tree_tested.py and test_pr_watch.py
skipped their fake-gh classes when ``jq`` was not on PATH, so on such a box
the suite passed having tested ci-tree-tested -- the gate that lets a push
to main skip the matrix -- not at all (#121). Nothing went red, because
nothing could.

This runs every OTHER test module in a child Python whose PATH holds every
executable the parent's does except ``jq``, and requires of that run:

- that jq really is hidden in it, and that it ran tests at all, so the
  check cannot pass by looking at nothing;
- no skip, for any reason: a skip anywhere in this suite is a test that
  reported OK without running, which is this bug wherever it appears;
- no failure, and only errors that name jq: a test that needs jq must stop
  before it runs, saying so. Removing the skip alone is not that -- the
  fake gh then fails mid-test, and every case that expects ``tested=false``
  passes for the wrong reason while the rest fail on an assertion.

The run is the suite itself, so a new test module is covered without being
listed here.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent

# Runs in the child: load every test module but this one (which would run
# itself again, without end), run them, and write what happened as JSON.
DRIVER = textwrap.dedent(
    """\
    import json, pathlib, shutil, sys, unittest

    here, me, out = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    sys.path.insert(0, str(here))
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for f in sorted(here.glob("test_*.py")):
        if f.stem != me:
            suite.addTests(loader.loadTestsFromName(f.stem))
    r = unittest.TestResult()
    suite.run(r)
    pathlib.Path(out).write_text(json.dumps({
        "jq": shutil.which("jq"),
        "ran": r.testsRun,
        "skipped": [[str(t), why] for t, why in r.skipped],
        "failures": [[str(t), tb] for t, tb in r.failures],
        "errors": [[str(t), tb] for t, tb in r.errors],
        "unexpected": [str(t) for t in r.unexpectedSuccesses],
    }))
    """
)


def path_without(tool: str, farm: pathlib.Path) -> str:
    """A PATH of one directory: a link to every executable on ours but tool.

    jq sits in /usr/bin beside git and bash, so no subset of the real PATH
    directories can drop it alone. The first of a name wins, as on PATH.
    """
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            link = farm / name
            if name == tool or os.path.lexists(link):
                continue
            link.symlink_to(os.path.join(d, name))
    return str(farm)


class NoSilentSkip(unittest.TestCase):
    def test_the_suite_without_jq_skips_nothing_and_names_jq(self) -> None:
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        farm = tmp / "bin"
        farm.mkdir()
        out = tmp / "result.json"
        env = {**os.environ, "PATH": path_without("jq", farm)}
        child = subprocess.run(
            [
                sys.executable,
                "-c",
                DRIVER,
                str(HERE),
                pathlib.Path(__file__).stem,
                str(out),
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
        )
        self.assertEqual(child.returncode, 0, child.stderr)
        r = json.loads(out.read_text())

        # Armed: jq is gone in the child, and the walk found tests.
        self.assertIsNone(r["jq"], "jq is still on the child's PATH")
        self.assertGreater(r["ran"], 0, "the child ran no tests")

        self.assertEqual(
            r["skipped"], [], "a test skipped, so it reported OK unrun"
        )
        self.assertEqual(r["unexpected"], [], "an expectedFailure passed")
        self.assertEqual(
            [t for t, _ in r["failures"]],
            [],
            "with jq hidden, a test ran and failed instead of stopping "
            "first, naming jq:\n"
            + "\n".join(tb for _, tb in r["failures"]),
        )
        silent = [t for t, tb in r["errors"] if not re.search(r"\bjq\b", tb)]
        self.assertEqual(
            silent,
            [],
            "an error that does not name jq:\n"
            + "\n".join(tb for _, tb in r["errors"]),
        )


if __name__ == "__main__":
    unittest.main()
