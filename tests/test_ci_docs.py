"""Behaviour of scripts/ci-docs.py, over a real temporary git repo.

``code=false`` lets every job docs cannot break skip, so the dangerous
answer is a false ``code=false``. Each case commits one change and runs the
script with ``CI_DOCS_RE`` and ``CI_DOCS_DIRS`` read from standard.mk -- the
defaults every adopter inherits, not a copy of them. Stdlib only, like the
script: ``python3 -m unittest discover -s tests``.
"""

from __future__ import annotations

import os
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

    def gitlink(self, path: str, sha: str) -> None:
        """Point a submodule entry at ``sha``, with no clone behind it."""
        (self.repo / path).mkdir(exist_ok=True)
        entry = f"160000,{sha},{path}"
        self.git("update-index", "--add", "--cacheinfo", entry)

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
                "--exclude",
                kw.get("exclude", ""),
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

    # #117: what a list of names cannot say. A symlink or a submodule
    # reaches contents that live somewhere else, so outside a docs
    # directory it is read like a deletion; and `ignore = all` in
    # .gitmodules hid a moved submodule from the diff altogether.
    def test_the_readme_turned_into_a_symlink_is_not_docs_only(self) -> None:
        (self.repo / "README.md").unlink()
        os.symlink("docs/gone.md", self.repo / "README.md")
        self.assertDocsOnly(False)

    def test_retargeting_a_readme_symlink_is_not_docs_only(self) -> None:
        (self.repo / "README.md").unlink()
        os.symlink("docs/a.md", self.repo / "README.md")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "the readme is a page")
        (self.repo / "README.md").unlink()
        os.symlink("docs/gone.md", self.repo / "README.md")
        self.assertDocsOnly(False)

    def test_a_symlink_inside_docs_is_docs(self) -> None:
        os.symlink("a.md", self.repo / "docs/index.md")
        self.assertDocsOnly(True)

    def test_a_submodule_moved_while_ignored_is_code(self) -> None:
        self.write(
            ".gitmodules",
            '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n'
            "\tignore = all\n",
        )
        self.gitlink("sub", "1" * 40)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "a submodule")
        self.gitlink("sub", "2" * 40)
        self.write("docs/a.md")
        self.assertDocsOnly(False)

    def test_a_repo_can_exclude_generated_docs(self) -> None:
        """just-makeit's docs/examples/ is built from example sources."""
        self.write("docs/examples/x.md")
        got = self.classify(exclude=r"^docs/examples/")
        self.assertEqual(got, {"docs": "false", "code": "true"})

    def test_an_excluded_path_beside_a_real_page_is_still_code(self) -> None:
        self.write("docs/a.md")
        self.write("docs/examples/x.md")
        got = self.classify(exclude=r"^docs/examples/")
        self.assertEqual(got, {"docs": "true", "code": "true"})

    # Fail-safe.
    def test_an_empty_diff_runs_everything(self) -> None:
        self.assertEqual(self.classify(), {"docs": "true", "code": "true"})

    def test_an_unreadable_base_runs_everything(self) -> None:
        self.assertEqual(
            self.classify(base="nope"), {"docs": "true", "code": "true"}
        )


if __name__ == "__main__":
    unittest.main()
