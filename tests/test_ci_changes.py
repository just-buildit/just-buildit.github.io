"""standard.mk's ``ci-changes``, over a real temporary git repo.

``ci-changes`` answers ``src=false`` when HEAD, against BASE, is a version
bump and nothing else, and a workflow's ``changes`` job then lets the
matrix skip. So the dangerous answer is a false ``src=false``: a real
change classified as a bump merges untested. Most cases here are ones that
must RUN; the ones that may skip are the shapes a release commit really has.

just-buildit.github.io#114: the rule rewrote the old version to the new one
EVERYWHERE in a changed manifest, so a dependency locked at the project's
old version was rewritten in the expected copy and not in HEAD, and a pure
bump ran the full matrix. Now only the lines HEAD changed are compared as
a bump.

These cases moved here from an inline step in ci.yml, so the target has one
home for its behaviour; the unittest job runs them.

Each test builds a throwaway repo: this ``standard.mk``, a minimal Makefile
with one VERSION_PROBES line, and a manifest of each kind a release touches.
``bump`` edits the project's OWN version lines and nothing else, as
``uv lock`` does. Stdlib only; needs GNU make and git.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

MAKEFILE = textwrap.dedent(
    """\
    TEST_CMD = @echo test
    TEST_FAST_CMD = @echo test-fast
    CLEAN_PATHS = dist/
    HAS_RELEASE = 1
    BUMP_VERSION_CMD = @echo bump
    RELEASE_WATCH_CMD = @echo watch
    VERSION_PROBES = pyproject.toml|sed -n 's/^version = "\\(.*\\)"/\\1/p' \\
      pyproject.toml
    include standard.mk
    """
)

PYPROJECT = textwrap.dedent(
    """\
    [project]
    name = "x"
    version = "1.2.3"
    dependencies = ["dep>=4.0.0"]
    """
)

UV_LOCK = textwrap.dedent(
    """\
    version = 1

    [[package]]
    name = "dep"
    version = "4.0.0"
    sdist = { url = "https://x/dep-4.0.0.tar.gz", hash = "sha256:aaaa" }

    [[package]]
    name = "x"
    version = "1.2.3"
    source = { editable = "." }
    """
)

#: A dependency locked at the project's own version -- the #114 trigger.
PINNED = textwrap.dedent(
    """\

    [[package]]
    name = "pinned"
    version = "1.2.3"
    sdist = { url = "https://x/pinned-1.2.3.tar.gz", hash = "sha256:bbbb" }
    """
)


class CiChanges(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        shutil.copy(ROOT / "standard.mk", self.repo / "standard.mk")
        self.write("Makefile", MAKEFILE)
        self.write("pyproject.toml", PYPROJECT)
        self.write("CMakeLists.txt", "project(x VERSION 1.2.3 LANGUAGES C)\n")
        self.write("uv.lock", UV_LOCK)
        self.write("src.c", "int f(void) { return 1; }\n")
        self.write("CHANGELOG.md", "# Changelog\n")
        self.commit("base")

    # -- helpers --------------------------------------------------------

    def git(self, *args: str) -> None:
        subprocess.run(
            ["git", *args], cwd=self.repo, check=True, capture_output=True
        )

    def commit(self, msg: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def write(self, path: str, text: str) -> None:
        (self.repo / path).write_text(text, encoding="utf-8")

    def edit(self, path: str, old: str, new: str) -> None:
        """Replace exactly one occurrence, so an edit that misses is loud."""
        text = (self.repo / path).read_text(encoding="utf-8")
        self.assertEqual(text.count(old), 1, f"{old!r} in {path}")
        self.write(path, text.replace(old, new))

    def bump(self) -> None:
        """1.2.3 -> 1.3.0 in the project's own version lines only."""
        self.edit("pyproject.toml", 'version = "1.2.3"', 'version = "1.3.0"')
        self.edit("CMakeLists.txt", "VERSION 1.2.3", "VERSION 1.3.0")
        self.edit(
            "uv.lock",
            'name = "x"\nversion = "1.2.3"',
            'name = "x"\nversion = "1.3.0"',
        )

    def classify(self, **env: str) -> "tuple[str, str]":
        """Commit the working tree and return ci-changes' (src, reason)."""
        self.commit("change")
        clean = {
            k: v
            for k, v in os.environ.items()
            if k not in ("BASE", "GITHUB_OUTPUT", "MAKEFLAGS", "MAKELEVEL")
        }
        r = subprocess.run(
            ["make", "-s", "--no-print-directory", "ci-changes"],
            cwd=self.repo,
            env={**clean, **env},
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        src = [ln for ln in r.stdout.splitlines() if ln.startswith("src=")]
        self.assertEqual(len(src), 1, r.stdout)
        return src[0][len("src=") :], r.stderr.strip()

    def assertSrc(self, want: str, **env: str) -> None:
        got, why = self.classify(**env)
        self.assertEqual(got, want, why)

    # -- may skip -------------------------------------------------------

    def test_a_bump_alone_skips(self) -> None:
        self.bump()
        self.write("CHANGELOG.md", "# Changelog\n\n## 1.3.0\n")
        self.assertSrc("false")

    def test_a_dependency_at_the_old_version_is_left_alone(self) -> None:
        # #114: the lock holds a dependency at 1.2.3 too. A release moves
        # the project's own entry and leaves that one where it is.
        self.write("uv.lock", UV_LOCK + PINNED)
        self.commit("lock a dependency at the project's version")
        self.bump()
        self.assertSrc("false")

    def test_a_manifest_without_a_final_newline_can_skip(self) -> None:
        self.write("VERSION", "1.2.3")
        self.commit("a version file with no final newline")
        self.bump()
        self.write("VERSION", "1.3.0")
        self.assertSrc("false")

    # -- must run -------------------------------------------------------

    def test_code_beside_a_bump_runs(self) -> None:
        self.bump()
        self.write("src.c", "int f(void) { return 2; }\n")
        self.assertSrc("true")

    def test_a_second_edit_in_a_bumped_manifest_runs(self) -> None:
        self.bump()
        self.edit("pyproject.toml", "dep>=4.0.0", "dep>=4.1.0")
        self.assertSrc("true")

    def test_a_version_line_that_changes_more_than_its_version_runs(
        self,
    ) -> None:
        self.bump()
        self.edit("CMakeLists.txt", "LANGUAGES C)", "LANGUAGES C CXX)")
        self.assertSrc("true")

    def test_a_dependency_moving_in_the_lockfile_runs(self) -> None:
        self.bump()
        self.edit("uv.lock", 'version = "4.0.0"', 'version = "4.1.0"')
        self.assertSrc("true")

    def test_a_dependency_moving_from_the_old_version_runs(self) -> None:
        # The #114 shape, but the pinned dependency DOES move, with the
        # bump: its version line reads as a bump, its hash does not.
        self.write("uv.lock", UV_LOCK + PINNED)
        self.commit("lock a dependency at the project's version")
        self.bump()
        moved = PINNED.replace("1.2.3", "1.3.0").replace("bbbb", "cccc")
        self.edit("uv.lock", PINNED, moved)
        self.assertSrc("true")

    def test_a_dot_in_the_version_is_not_a_wildcard(self) -> None:
        # Read as a pattern, 1.2.3 matches 1x2x3, and this line would read
        # as a bump.
        self.write("ref.txt", "pin 1x2x3\n")
        self.commit("a string the version matches only as a regex")
        self.bump()
        self.write("ref.txt", "pin 1.3.0\n")
        self.assertSrc("true")

    def test_dropping_the_final_newline_runs(self) -> None:
        self.write("VERSION", "1.2.3\n")
        self.commit("a version file")
        self.bump()
        self.write("VERSION", "1.3.0")
        self.assertSrc("true")

    def test_code_without_a_bump_runs(self) -> None:
        self.write("src.c", "int f(void) { return 2; }\n")
        self.assertSrc("true")

    def test_a_bump_that_adds_a_file_runs(self) -> None:
        self.bump()
        self.write("new.txt", "x\n")
        self.assertSrc("true")

    def test_a_base_not_in_the_clone_runs(self) -> None:
        self.bump()
        self.assertSrc("true", BASE="deadbeef")

    # -- the output contract ---------------------------------------------

    def test_the_answer_reaches_github_output(self) -> None:
        self.bump()
        out = self.repo.parent / (self.repo.name + ".gho")
        self.addCleanup(lambda: out.unlink(missing_ok=True))
        out.write_text("")
        self.assertSrc("false", GITHUB_OUTPUT=str(out))
        self.assertEqual(out.read_text().splitlines(), ["src=false"])


if __name__ == "__main__":
    unittest.main()
