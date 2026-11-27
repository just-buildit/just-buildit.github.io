"""No pipeline under pipefail ends in a reader that stops early.

``grep -q`` exits at its first match, and ``head`` once it has its lines.
A producer still writing then takes SIGPIPE and exits 141, and under
``pipefail`` the pipeline fails, though the reader got what it wanted. Whether
it fails depends on whether the producer had finished writing first. The
close-keywords step's ``make -pn lint | grep -qE ...`` failed every time on a
local box (rc 141, 3 of 3) and passed on the runner by timing alone. Under
``!`` the race inverts: ``! make ci-image-config | grep -qx packager=1`` is
TRUE when grep matched and make took SIGPIPE, so an owed packager image check
was skipped.

``grep ... >/dev/null`` and ``sed -n 1p`` read all of their input, so the
producer always finishes and the exit status is the reader's verdict alone.

What is scanned, and what is not:

- every workflow this repo runs (``.github/workflows``) and every one it
  publishes for adopters to vendor (``github/workflows``). A step runs under
  pipefail when it sets it or names ``shell: bash`` (GitHub's ``bash -eo
  pipefail``); the rest are held too, since adding either later is one line
  and would arm the race silently;
- each ``scripts/*.sh`` that sets pipefail;
- NOT ``standard.mk``: make runs a recipe under ``/bin/sh -c`` with no
  pipefail, so a pipeline's status there is its last command's, and an
  early reader cannot fail it.

The scan reads PIPELINES, not lines: a command continued with a trailing
``\\`` or ``|`` is joined first, and the words are split as the shell splits
them, so ``grep -E -q``, ``egrep -q`` and a pipe split across lines are all
seen. Every file in scope is read, so a new step or script is covered
without being listed.
"""

from __future__ import annotations

import pathlib
import re
import shlex
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW_DIRS = (ROOT / ".github" / "workflows", ROOT / "github" / "workflows")
SCRIPTS = ROOT / "scripts"

#: A YAML key opening a block scalar (``run: |``, ``body: >-``): its ``|``
#: is YAML's, not a pipe.
_BLOCK = re.compile(r"^\s*(?:-\s+)?[\w.-]+:\s*[|>][-+0-9]*\s*(?:#.*)?$")
#: A script that turns pipefail on.
_PIPEFAIL = re.compile(r"^\s*set\b[^#\n]*\bpipefail\b", re.M)
#: grep's short options that stop reading early: -q, -m N, -l, -L.
_EARLY = set("qmlL")
#: grep's short options that take an argument: the rest of the bundle, or
#: the next word, is that argument and not an option.
_TAKES_ARG = set("efmABCDd")
_GREPS = {"grep", "egrep", "fgrep"}


def pipelines(text: str, yaml: bool = False) -> "list[tuple[int, str]]":
    """Each logical command line of *text*, with its first line's number.

    >>> pipelines('a |\\n  grep -q x\\nb \\\\\\n c\\n')
    [(1, 'a | grep -q x'), (3, 'b  c')]
    >>> pipelines('run: |\\n  a || b\\n', yaml=True)
    [(2, 'a || b')]
    """
    out: list[tuple[int, str]] = []
    held, first = "", 0
    for n, raw in enumerate(text.splitlines(), 1):
        if yaml and not held and _BLOCK.match(raw):
            continue
        line = raw.strip()
        if not held:
            first = n
        if line.endswith("\\"):
            held += line[:-1] + " "
            continue
        if line.endswith("|") and not line.endswith("||"):
            held += line + " "
            continue
        out.append((first, held + line))
        held = ""
    if held:
        out.append((first, held.strip()))
    return out


def _words(line: str) -> "list[str]":
    """The shell words and operators of *line*. A quote left open (a jq
    program spanning lines) splits on whitespace, pipes apart."""
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = "#"
        return list(lex)
    except ValueError:
        return line.replace("|", " | ").split()


def early_reader(cmd: "list[str]") -> bool:
    """Whether the command *cmd* (its words) may stop reading its input.

    >>> early_reader(["grep", "-E", "-q", "x"])
    True
    >>> early_reader(["grep", "x", "--quiet"])
    True
    >>> early_reader(["egrep", "-xq", "y"]), early_reader(["fgrep", "-m1"])
    (True, True)
    >>> early_reader(["head", "-n1"])
    True
    >>> early_reader(["grep", "-e", "-q", "x"])
    False
    >>> early_reader(["grep", "-c", "x"]), early_reader(["sed", "-n", "1p"])
    (False, False)
    """
    if not cmd:
        return False
    name = cmd[0].rsplit("/", 1)[-1]
    if name == "head":
        return True
    if name not in _GREPS:
        return False
    skip = False
    for w in cmd[1:]:
        if skip:
            skip = False
            continue
        if w == "--":
            break
        if w.startswith("--"):
            if w in (
                "--quiet",
                "--silent",
                "--files-with-matches",
                "--files-without-match",
            ) or w.startswith("--max-count"):
                return True
            continue
        if w.startswith("-") and len(w) > 1:
            for i, ch in enumerate(w[1:]):
                if ch in _EARLY:
                    return True
                if ch in _TAKES_ARG:
                    skip = i == len(w) - 2
                    break
    return False


def offenders(text: str, yaml: bool = False) -> "list[tuple[int, str]]":
    """Each (line number, pipeline) of *text* piping into an early reader.

    >>> offenders('a | grep -q x\\nb | grep x >/dev/null\\n')
    [(1, 'a | grep -q x')]
    >>> offenders('! make c | grep -qx packager=1')
    [(1, '! make c | grep -qx packager=1')]
    >>> [n for n, _ in offenders('x |\\n  egrep -q y\\nz | grep -E -q w\\n')]
    [1, 3]
    >>> offenders('v=$(gh --version | head -n 1)')
    [(1, 'v=$(gh --version | head -n 1)')]
    >>> offenders('grep -q x file\\na || grep -q y f\\n# a | grep -q c\\n')
    []
    >>> offenders('run: |\\n  grep -q x f\\n', yaml=True)
    []
    """
    found = []
    for n, line in pipelines(text, yaml):
        words = _words(line)
        for i, w in enumerate(words):
            if w not in ("|", "|&"):
                continue
            cmd = []
            for x in words[i + 1 :]:
                if x and set(x) <= set("();<>|&"):
                    break
                cmd.append(x)
            if early_reader(cmd):
                found.append((n, line))
                break
    return found


def scope() -> "list[tuple[pathlib.Path, bool]]":
    """Every file the scan reads, and whether it is YAML."""
    files = [
        (p, True) for d in WORKFLOW_DIRS for p in sorted(d.glob("*.yml"))
    ]
    files += [
        (p, False)
        for p in sorted(SCRIPTS.glob("*.sh"))
        if _PIPEFAIL.search(p.read_text(encoding="utf-8"))
    ]
    return files


class NoEarlyReaderPipe(unittest.TestCase):
    def test_the_scan_reads_each_place(self) -> None:
        # A scope that read nothing has checked nothing, in any of the three.
        files = [p for p, _ in scope()]
        for where in (*WORKFLOW_DIRS, SCRIPTS):
            self.assertTrue(
                [p for p in files if p.parent == where],
                f"the scan read nothing under {where}",
            )

    def test_no_pipeline_ends_in_an_early_reader(self) -> None:
        found = [
            f"{path.relative_to(ROOT)}:{n}: {line}"
            for path, yaml in scope()
            for n, line in offenders(path.read_text(encoding="utf-8"), yaml)
        ]
        self.assertEqual(
            found,
            [],
            "a pipe into `grep -q` or `head` fails under pipefail when the "
            "producer is still writing (SIGPIPE, rc 141), and a `!` before "
            "it inverts that; use `grep ... >/dev/null` or `sed -n 1p`, "
            "which drain their input:\n" + "\n".join(found),
        )


def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, _: object
) -> unittest.TestSuite:
    import doctest

    tests.addTests(doctest.DocTestSuite())
    return tests


if __name__ == "__main__":
    unittest.main()
