"""Behaviour of scripts/ci-docs.py, over a real temporary git repo.

``code=false`` lets every job docs cannot break skip, so the dangerous
answer is a false ``code=false``. Each case commits one change and runs the
script with ``CI_DOCS_RE`` and ``CI_DOCS_DIRS`` read from standard.mk -- the
defaults every adopter inherits, not a copy of them. Stdlib only, like the
script: ``python3 -m unittest discover -s tests``.
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ci-docs.py"


def _default(var: str) -> str:
    """A standard.mk ``?=`` default as make passes it (``$$`` -> ``$``)."""
    text = (ROOT / "standard.mk").read_text(encoding="utf-8")
    m = re.search(rf"^{var}\s*\?=\s*(.+)$", text, re.M)
    assert m, f"standard.mk declares no {var}"
    return m.group(1).strip().replace("$$", "$").replace("\\\\", "\\")


class CiDocs(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        for f in ("README.md", "docs/a.md", "src/x.c", "pyproject.toml"):
            self.write(f, "1\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    def git(self, *args: str) -> None:
        subprocess.run(
            ["git", *args], cwd=self.repo, check=True, capture_output=True
        )

    def write(self, path: str, text: str = "2\n") -> None:
        (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / path).write_text(text)

    def classify(self, base: str = "HEAD^", **kw: str) -> dict[str, str]:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change", "--allow-empty")
        r = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--base",
                base,
                "--re",
                kw.get("re", _default("CI_DOCS_RE")),
                "--dirs",
                kw.get("dirs", _default("CI_DOCS_DIRS")),
            ],
            cwd=self.repo,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return dict(line.split("=", 1) for line in r.stdout.split())

    def assertDocsOnly(self, want: bool) -> None:
        got = self.classify()
        self.assertEqual(got["code"], "false" if want else "true", got)

    # Docs-only.
    def test_a_page_edit_is_docs_only(self) -> None:
        self.write("docs/a.md")
        self.assertDocsOnly(True)

    def test_a_new_page_is_docs_only(self) -> None:
        self.write("docs/new/page.md")
        self.assertDocsOnly(True)

    def test_readme_mkdocs_and_fragments_are_docs(self) -> None:
        self.write("README.md")
        self.write("mkdocs.yml")
        self.write("changelog.d/added/x.md")
        self.assertDocsOnly(True)

    def test_retiring_a_page_is_docs_only(self) -> None:
        (self.repo / "docs/a.md").unlink()
        self.assertDocsOnly(True)

    # Not docs-only: each would skip a job it can break.
    def test_code_is_not_docs_only(self) -> None:
        self.write("src/x.c")
        self.assertDocsOnly(False)

    def test_docs_plus_code_is_code(self) -> None:
        self.write("docs/a.md")
        self.write("src/x.c")
        self.assertEqual(self.classify(), {"docs": "true", "code": "true"})

    def test_a_nested_readme_is_not_docs(self) -> None:
        self.write("src/README.md")
        self.assertDocsOnly(False)

    def test_deleting_the_readme_is_not_docs_only(self) -> None:
        """pyproject's `readme` reads it: removal can break the wheel."""
        (self.repo / "README.md").unlink()
        self.assertDocsOnly(False)

    def test_a_repo_can_exclude_generated_docs(self) -> None:
        """just-makeit's docs/examples/ is built from example sources."""
        self.write("docs/examples/x.md")
        rx = r"^(?!docs/examples/)(docs/|README\.md$)"
        self.assertEqual(self.classify(re=rx)["code"], "true")

    # Fail-safe.
    def test_an_empty_diff_runs_everything(self) -> None:
        self.assertEqual(self.classify(), {"docs": "true", "code": "true"})

    def test_an_unreadable_base_runs_everything(self) -> None:
        self.assertEqual(
            self.classify(base="nope"), {"docs": "true", "code": "true"}
        )


if __name__ == "__main__":
    unittest.main()
