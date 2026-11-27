"""No workflow step pipes a producer into ``grep -q``.

GitHub runs a ``run:`` step under ``bash -e -o pipefail``, and several steps
here set ``pipefail`` themselves. ``grep -q`` exits at its first match, so a
producer still writing gets SIGPIPE and exits 141, and ``pipefail`` makes the
whole pipeline fail although the match was found. Whether it fails depends
on whether the producer finished writing before grep exited: the
close-keywords step's ``make -pn lint | grep -qE ...`` failed every time on
a local box (rc 141, 3 of 3) and passed on the runner by timing alone.

``grep ... >/dev/null`` reads all of its input, so the producer always
finishes, and the exit status is grep's verdict and nothing else.

Every workflow is scanned, so a new step is covered without being listed.
"""

from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

#: A pipe into grep carrying -q among its short options, e.g. ``| grep -q``,
#: ``| grep -qE``, ``|grep -xq``. Long ``--quiet`` / ``--silent`` too.
_GREP_Q = re.compile(r"\|\s*grep\s+(?:-[A-Za-z]*q[A-Za-z]*\b|--quiet\b|--silent\b)")


def offenders(text: str) -> "list[tuple[int, str]]":
    """Each (line number, line) of *text* that pipes into a quiet grep.

    >>> offenders('a | grep -q x\\nb | grep x >/dev/null\\n')
    [(1, 'a | grep -q x')]
    >>> offenders('make -pn | grep -qE "^lint:"')
    [(1, 'make -pn | grep -qE "^lint:"')]
    >>> offenders('x | grep --quiet y')
    [(1, 'x | grep --quiet y')]
    >>> offenders('grep -q x file')
    []
    """
    return [
        (n, line.strip())
        for n, line in enumerate(text.splitlines(), 1)
        if _GREP_Q.search(line)
    ]


class NoQuietGrepPipe(unittest.TestCase):
    def test_the_scan_reads_workflows(self) -> None:
        files = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(files, f"no workflow found under {WORKFLOWS}")

    def test_no_workflow_pipes_into_grep_q(self) -> None:
        found = [
            f"{path.relative_to(ROOT)}:{n}: {line}"
            for path in sorted(WORKFLOWS.glob("*.yml"))
            for n, line in offenders(path.read_text(encoding="utf-8"))
        ]
        self.assertEqual(
            found,
            [],
            "a pipe into `grep -q` fails under pipefail when the producer "
            "is still writing (SIGPIPE, rc 141); use "
            "`grep ... >/dev/null`, which drains its input:\n" + "\n".join(found),
        )


if __name__ == "__main__":
    unittest.main()
