"""The CI toolchain image standard (HAS_CI_IMAGE): its pin, Dockerfile, workflow.

The image is a snapshot: every input pinned, moved only by a commit. These
check the properties that claim rests on -- the pin is complete and round
trips; a new apt snapshot ALONE owes no repin while a moved fingerprint or
source does; the Dockerfile has no default for any input and installs
through a sha256-verified installer release; the workflow writes the pin
through the script alone and repins only when something moved. Stdlib only,
like the script: ``python3 -m unittest discover -s tests``.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ci-image.py"
DOCKERFILE = ROOT / "docker" / "ci.Dockerfile"
WORKFLOW = ROOT / "github" / "workflows" / "ci-image.yml"
BASES = "ubuntu:24.04 ubuntu:22.04"

D = "sha256:" + "a" * 64
GOOD = {
    "CI_APT_SNAPSHOT": "20261002T000000Z",
    "CI_JB_VERSION": "v0.7.0",
    "CI_JB_SHA256": "b" * 64,
    "CI_BASE_2404": f"ubuntu:24.04@{D}",
    "CI_IMAGE_2404": f"ghcr.io/o/r-ci@{D}",
    "CI_IMAGE_FINGERPRINT_2404": "c" * 64,
    "CI_BASE_2204": f"ubuntu:22.04@{D}",
    "CI_IMAGE_2204": f"ghcr.io/o/r-ci@{D}",
    "CI_IMAGE_FINGERPRINT_2204": "d" * 64,
    "CI_IMAGE_SOURCE_HASH": "e" * 64,
}


class _Tree(unittest.TestCase):
    """A temporary adopter: the image sources, and the script run in it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._tmp.name)
        (self.root / "docker").mkdir()
        (self.root / ".github").mkdir()
        (self.root / "docker" / "ci.Dockerfile").write_text("FROM x\n")
        (self.root / "bootstrap.toml").write_text("[dev.apt]\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_script(self, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.root, input=stdin, capture_output=True, text=True,
            env={**os.environ, "CI_IMAGE_BASES": BASES},
        )

    def write_pin(self, values: "dict[str, str]", out: str = ".github/ci-images.env") -> subprocess.CompletedProcess:
        lines = "".join(f"{k}={v}\n" for k, v in values.items())
        return self.run_script("write-pin", "--out", out, stdin=lines)

    def source_hash(self) -> str:
        return self.run_script("source-hash").stdout.strip()


class TestThePin(_Tree):
    def test_a_complete_pin_round_trips_in_a_fixed_order(self):
        r = self.write_pin(GOOD)
        self.assertEqual(r.returncode, 0, r.stderr)
        text = (self.root / ".github/ci-images.env").read_text()
        body = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
        self.assertEqual(dict(ln.split("=", 1) for ln in body), GOOD)
        # Column 0 throughout: make `include`s it.
        self.assertFalse([ln for ln in text.splitlines() if ln[:1].isspace()])

    def test_a_pin_missing_or_misforming_a_key_is_refused(self):
        for k in ("CI_JB_SHA256", "CI_IMAGE_2204", "CI_APT_SNAPSHOT"):
            with self.subTest(missing=k):
                vals = {x: v for x, v in GOOD.items() if x != k}
                self.assertNotEqual(self.write_pin(vals).returncode, 0)
        with self.subTest(bad="unpinned base"):
            vals = {**GOOD, "CI_BASE_2404": "ubuntu:24.04"}
            self.assertNotEqual(self.write_pin(vals).returncode, 0)


class TestWhatOwesARepin(_Tree):
    def _changed(self, **moved: str) -> str:
        self.write_pin(GOOD)
        self.write_pin({**GOOD, **moved}, out="new.env")
        return self.run_script("changed", "--new", "new.env").stdout.strip()

    def test_a_new_snapshot_alone_owes_nothing(self):
        self.assertEqual(
            self._changed(CI_APT_SNAPSHOT="20261009T000000Z",
                          CI_IMAGE_2404=f"ghcr.io/o/r-ci@sha256:{'f' * 64}"),
            "changed=0",
        )

    def test_a_moved_fingerprint_owes_a_repin(self):
        self.assertEqual(
            self._changed(CI_IMAGE_FINGERPRINT_2204="9" * 64), "changed=1")

    def test_moved_sources_owe_a_repin(self):
        self.assertEqual(self._changed(CI_IMAGE_SOURCE_HASH="9" * 64),
                         "changed=1")


class TestTheSourceHash(_Tree):
    def test_it_moves_with_each_input_and_with_the_extra_appearing(self):
        seen = {self.source_hash()}
        for path, text in (
            ("docker/ci.Dockerfile", "FROM y\n"),
            ("bootstrap.toml", "[dev.apt]\npackages = ['jq']\n"),
            ("docker/ci-extra.sh", "true\n"),
        ):
            with self.subTest(path=path):
                (self.root / path).write_text(text)
                h = self.source_hash()
                self.assertNotIn(h, seen)
                seen.add(h)

    def test_check_refuses_a_pin_from_other_sources(self):
        self.assertNotEqual(self.run_script("check").returncode, 0,
                            "no pin must fail, not pass")
        self.write_pin({**GOOD, "CI_IMAGE_SOURCE_HASH": self.source_hash()})
        self.assertEqual(self.run_script("check").returncode, 0)
        (self.root / "bootstrap.toml").write_text("[dev.apt]\n# moved\n")
        r = self.run_script("check")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("without a repin", r.stdout)


class TestKeysAndFingerprints(_Tree):
    def test_the_pin_key_is_the_tags_digits(self):
        self.assertEqual(self.run_script("key", "ubuntu:24.04").stdout.strip(),
                         "2404")
        self.assertEqual(
            self.run_script("key", f"ubuntu:22.04@{D}").stdout.strip(), "2204")

    def test_joining_arches_ignores_their_order(self):
        a = self.run_script("join-fingerprint", "amd64=a", "arm64=b").stdout
        b = self.run_script("join-fingerprint", "arm64=b", "amd64=a").stdout
        self.assertEqual(a, b)
        self.assertNotEqual(
            a, self.run_script("join-fingerprint", "amd64=a", "arm64=c").stdout)


def _instructions(text: str) -> "list[str]":
    joined = re.sub(r"\\\n", " ", text)
    return [ln.strip() for ln in joined.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


class TestTheDockerfile(unittest.TestCase):
    text = DOCKERFILE.read_text(encoding="utf-8")

    def test_no_input_has_a_default(self):
        """A default would be a second copy of the pin, and the stale one."""
        args = [i for i in _instructions(self.text) if i.startswith("ARG ")]
        names = {a.split()[1].split("=")[0] for a in args}
        self.assertTrue({"BASE", "APT_SNAPSHOT", "JB_VERSION", "JB_SHA256",
                         "CI_IMAGE_GROUPS"} <= names, names)
        self.assertEqual([a for a in args if "=" in a], [])

    def test_the_installer_is_a_verified_release_not_jbx(self):
        code = " ".join(_instructions(self.text))
        self.assertIn("sha256sum -c", code)
        self.assertIn("releases/download/${JB_VERSION}/", code)
        for banned in ("get-jb.sh", "jbx install-deps"):
            self.assertNotIn(banned, code,
                             "jbx resolves install-deps at run time: pinning "
                             "it pins nothing")

    def test_every_apt_get_is_bounded(self):
        calls = [c for i in _instructions(self.text) if i.startswith("RUN ")
                 for c in re.split(r"&&|;", i) if re.search(r"\bapt-get\b", c)]
        self.assertGreaterEqual(len(calls), 2, calls)
        self.assertEqual(
            [c for c in calls if "Timeout=" not in c or "Retries=" not in c], [])

    def test_the_optional_extra_cannot_fail_the_copy(self):
        """A COPY wildcard matching nothing fails; a file always present
        rides along, and the directory is a wildcard too."""
        self.assertRegex(self.text, r"(?m)^COPY bootstrap\.toml docke\[r\]/ci-extra\.s\[h\] ")


class TestTheWorkflow(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")

    def test_the_pin_is_written_only_by_the_script(self):
        self.assertIn("scripts/ci-image.py write-pin", self.text)
        self.assertEqual(self.text.count("> .github/ci-images.env"), 0)

    def test_it_repins_only_when_something_moved(self):
        self.assertIn("steps.pin.outputs.changed == '1'", self.text)

    def test_an_unlanded_branch_repin_keeps_the_run_red(self):
        """Branch landing has no PR to be the signal, and a green run
        notifies nobody (doppler#1737): every default-branch run must fail
        while ci/repin-image's pin differs from the default branch's."""
        i = self.text.index("An unlanded repin keeps this run red")
        step = self.text[i:]
        self.assertIn("needs.resolve.outputs.landing == 'branch'", step)
        self.assertIn("-- .github/ci-images.env", step)
        self.assertIn("exit 1", step)
        # It is the LAST step: nothing after it can be skipped by its red.
        self.assertNotIn("\n      - name:", step[1:])

    def test_both_arches_build_natively(self):
        self.assertIn("ubuntu-24.04-arm", self.text)
        self.assertNotIn("setup-qemu", self.text)

    def test_no_env_var_shadows_a_bash_special(self):
        """`GROUPS: ...` in a step's env read as bash's builtin GROUPS array
        (the user's gids): `$GROUPS` expanded to a gid and every image was
        built installing no bootstrap group, with no error anywhere."""
        special = {"GROUPS", "UID", "EUID", "PPID", "RANDOM", "SECONDS",
                   "LINENO", "BASHPID", "BASH_VERSINFO", "SHELLOPTS",
                   "BASHOPTS", "FUNCNAME", "HOSTNAME", "HOSTTYPE", "OSTYPE"}
        keys = set(re.findall(r"(?m)^\s+([A-Z][A-Z0-9_]*):", self.text))
        self.assertTrue(keys, "the scan must find the env keys")
        self.assertEqual(sorted(keys & special), [])

    def test_settings_come_from_the_makefile(self):
        self.assertIn("make -s ci-image-config", self.text)
        self.assertIn("make ci-image-smoke", self.text)


class TestOptIn(unittest.TestCase):
    def test_the_files_are_vendored_only_under_has_ci_image(self):
        mk = (ROOT / "standard.mk").read_text(encoding="utf-8")
        block = mk[mk.index("ifeq ($(HAS_CI_IMAGE),1)"):]
        block = block[: block.index("\nendif")]
        for f in ("scripts/ci-image.py", "docker/ci.Dockerfile",
                  ".github/workflows/ci-image.yml"):
            self.assertIn(f, block)
            self.assertNotIn(f"VENDORED_FILES += {f}",
                             mk.replace(block, ""))
        # `.github/` is served from `github/`: the source must exist there.
        self.assertTrue(WORKFLOW.exists())


if __name__ == "__main__":
    unittest.main()
