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


    # A bootstrap.toml as an adopter writes one: the release version in
    # [project], which no image layer reads, then the groups the image does.
    BOOT = (
        '[project]\nname = "p"\nversion = "{v}"\n\n'
        "[project.urls]\nhome = 'x'\n\n"
        "[dev.apt]\npackages = [\n  'jq',\n]{extra}\n"
    )

    def _boot(self, v: str = "0.1.0", extra: str = "") -> str:
        (self.root / "bootstrap.toml").write_text(
            self.BOOT.format(v=v, extra=extra))
        return self.source_hash()

    def test_a_version_bump_owes_no_repin(self):
        """doppler-dsp/doppler#1765: a release bumped the hash it never fed."""
        h = self._boot("0.1.0")
        self.assertEqual(self._boot("0.2.0"), h)
        self.write_pin({**GOOD, "CI_IMAGE_SOURCE_HASH": h})
        self.assertEqual(self.run_script("check").returncode, 0)

    def test_a_table_after_project_still_moves_it(self):
        """Leaving [project] ends at the next header, not the end of file."""
        h = self._boot()
        self.assertNotEqual(self._boot(extra="\n# moved"), h)
        moved = self.BOOT.format(v="0.1.0", extra="").replace("'jq'", "'yq'")
        (self.root / "bootstrap.toml").write_text(moved)
        self.assertNotEqual(self.source_hash(), h)


    def test_an_element_shaped_like_a_header_is_not_one(self):
        """``['project']`` alone on a line, inside an array, is a value."""
        boot = self.BOOT.format(v="0.1.0", extra="").replace(
            "  'jq',\n", "  ['project']\n")
        (self.root / "bootstrap.toml").write_text(boot)
        h = self.source_hash()
        (self.root / "bootstrap.toml").write_text(
            boot + "retries = 3\n")
        self.assertNotEqual(self.source_hash(), h,
                            "the key after the array went unhashed")


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


D2 = "sha256:" + "b" * 64
PACKAGER_ON = {
    "PACKAGER_IMAGE_ENABLED": "1",
    "PACKAGER_GROUPS": "packager",
    "PACKAGER_BASE_AMD64": "quay.io/pypa/manylinux_2_28_x86_64",
    "PACKAGER_BASE_ARM64": "quay.io/pypa/manylinux_2_28_aarch64",
}
PACKAGER_GOOD = {
    **GOOD,
    "CI_PACKAGER_BASE_AMD64": f"quay.io/pypa/manylinux_2_28_x86_64@{D}",
    "CI_PACKAGER_BASE_ARM64": f"quay.io/pypa/manylinux_2_28_aarch64@{D}",
    "CI_PACKAGER_IMAGE": f"ghcr.io/o/r-packager@{D}",
    "CI_PACKAGER_FINGERPRINT": "e" * 64,
    "CI_PACKAGER_SOURCE_HASH": "f" * 64,
}


class TestThePackagerFamily(_Tree):
    """HAS_PACKAGER_IMAGE: a second image in the same pin, off by default."""

    def setUp(self) -> None:
        super().setUp()
        (self.root / "docker" / "packager.Dockerfile").write_text("FROM x\n")

    def run_on(self, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
        """The script with the packager on, as the workflow runs it."""
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.root, input=stdin, capture_output=True, text=True,
            env={**os.environ, "CI_IMAGE_BASES": BASES, **PACKAGER_ON},
        )

    def pin_on(self, values: "dict[str, str]", out: str = ".github/ci-images.env"):
        lines = "".join(f"{k}={v}\n" for k, v in values.items())
        return self.run_on("write-pin", "--out", out, stdin=lines)

    def packager_hash(self) -> str:
        return self.run_on("packager-source-hash").stdout.strip()

    def test_a_dev_group_edit_owes_the_packager_nothing(self):
        """Only the packager's own groups feed its hash (one declaration)."""
        (self.root / "bootstrap.toml").write_text(
            "[dev.apt]\npackages = ['jq']\n\n[packager.dnf]\npackages = ['rpm-build']\n")
        before, ci_before = self.packager_hash(), self.source_hash()
        (self.root / "bootstrap.toml").write_text(
            "[dev.apt]\npackages = ['jq', 'yq']\n\n[packager.dnf]\npackages = ['rpm-build']\n")
        self.assertEqual(self.packager_hash(), before)
        # ...while the CI image, which installs dev, does owe a repin.
        self.assertNotEqual(self.source_hash(), ci_before)

    def test_naming_a_different_group_moves_it(self):
        before = self.packager_hash()
        r = subprocess.run(
            [sys.executable, str(SCRIPT), "packager-source-hash"],
            cwd=self.root, capture_output=True, text=True,
            env={**os.environ, "PACKAGER_IMAGE_ENABLED": "1",
                 "CI_IMAGE_BASES": BASES, "PACKAGER_GROUPS": "dev"})
        self.assertNotEqual(r.stdout.strip(), before)

    def test_with_no_groups_it_refuses_rather_than_hashing_nothing(self):
        r = subprocess.run(
            [sys.executable, str(SCRIPT), "packager-source-hash"],
            cwd=self.root, capture_output=True, text=True,
            env={**os.environ, "PACKAGER_IMAGE_ENABLED": "1",
                 "CI_IMAGE_BASES": BASES, "PACKAGER_GROUPS": ""})
        self.assertNotEqual(r.returncode, 0)

    def test_on_the_pin_appends_the_packager_block_after_the_ci_block(self):
        r = self.pin_on(PACKAGER_GOOD)
        self.assertEqual(r.returncode, 0, r.stderr)
        keys = [ln.split("=", 1)[0] for ln in
                (self.root / ".github/ci-images.env").read_text().splitlines()
                if ln and not ln.startswith("#")]
        self.assertEqual(keys[-5:], [
            "CI_PACKAGER_BASE_AMD64", "CI_PACKAGER_BASE_ARM64",
            "CI_PACKAGER_IMAGE", "CI_PACKAGER_FINGERPRINT",
            "CI_PACKAGER_SOURCE_HASH"])
        self.assertEqual(keys[: len(keys) - 5], list(GOOD)[: len(GOOD)])

    def test_off_a_pin_without_the_packager_keys_is_still_complete(self):
        """The flag off must not demand packager keys: an adopter is unchanged."""
        self.write_pin({**GOOD, "CI_IMAGE_SOURCE_HASH": self.source_hash()})
        self.assertEqual(self.run_script("check").returncode, 0)

    def test_on_a_pin_missing_a_packager_key_is_refused(self):
        for k in ("CI_PACKAGER_IMAGE", "CI_PACKAGER_SOURCE_HASH"):
            with self.subTest(missing=k):
                vals = {x: v for x, v in PACKAGER_GOOD.items() if x != k}
                self.assertNotEqual(self.pin_on(vals).returncode, 0)

    def test_on_an_unpinned_packager_base_is_refused(self):
        vals = {**PACKAGER_GOOD, "CI_PACKAGER_BASE_ARM64": "quay.io/x/y"}
        self.assertNotEqual(self.pin_on(vals).returncode, 0)

    def test_the_packager_dockerfile_is_not_an_input_to_the_ci_image(self):
        """Adding the packager must not move any adopter's CI source hash."""
        before = self.source_hash()
        (self.root / "docker" / "packager.Dockerfile").write_text("FROM y\n")
        self.assertEqual(self.source_hash(), before)

    def test_its_source_hash_moves_with_its_dockerfile_and_bootstrap(self):
        seen = {self.packager_hash()}
        for path, text in (
            ("docker/packager.Dockerfile", "FROM y\n"),
            ("bootstrap.toml", "[packager.dnf]\npackages = ['rpm-build']\n"),
        ):
            with self.subTest(path=path):
                (self.root / path).write_text(text)
                h = self.packager_hash()
                self.assertNotIn(h, seen)
                seen.add(h)

    def test_check_refuses_a_packager_pin_from_other_sources(self):
        self.pin_on({**PACKAGER_GOOD, "CI_IMAGE_SOURCE_HASH": self.source_hash()})
        r = self.run_on("check")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("packager's sources", r.stdout)
        self.pin_on({**PACKAGER_GOOD, "CI_IMAGE_SOURCE_HASH": self.source_hash(),
                     "CI_PACKAGER_SOURCE_HASH": self.packager_hash()})
        self.assertEqual(self.run_on("check").returncode, 0)

    def test_a_moved_packager_fingerprint_owes_a_repin_and_a_snapshot_alone_does_not(self):
        self.pin_on(PACKAGER_GOOD)
        self.pin_on({**PACKAGER_GOOD, "CI_APT_SNAPSHOT": "20261009T000000Z"},
                    out="new.env")
        self.assertEqual(self.run_on("changed", "--new", "new.env").stdout.strip(),
                         "changed=0")
        self.pin_on({**PACKAGER_GOOD, "CI_PACKAGER_FINGERPRINT": "9" * 64},
                    out="new.env")
        self.assertEqual(self.run_on("changed", "--new", "new.env").stdout.strip(),
                         "changed=1")


_FAKE_DOCKER = r"""#!/usr/bin/env python3
# A docker that answers `buildx imagetools inspect REF` from a script: the
# file named for REF (/ and : as _) holds one outcome per call, the last
# repeating. Every call is logged, so a test can see who was asked.
import json, os, pathlib, sys
d = pathlib.Path(os.environ["FAKE_DOCKER_DIR"])
ref = sys.argv[4]
with open(d / "calls.log", "a") as log:
    log.write(ref + "\n")
f = d / ref.replace("/", "_").replace(":", "_").replace("@", "_")
lines = f.read_text().split() if f.exists() else ["unknown"]
n = sum(1 for ln in (d / "calls.log").read_text().split() if ln == ref)
out = lines[min(n, len(lines)) - 1]
if out == "ok":
    print(json.dumps({"digest": "sha256:" + "f" * 64}))
    sys.exit(0)
sys.stderr.write({
    "429": "ERROR: toomanyrequests: Rate exceeded",
    "quota": "ERROR: toomanyrequests: Data limit exceeded",
    "unknown": "ERROR: " + ref + ": not found: manifest unknown",
}[out] + "\n")
sys.exit(1)
"""

REG = "public.ecr.aws/docker/library"
MIRROR = "mirror.gcr.io/library"
PINNED = f"ubuntu:24.04@{D}"


class TestTheBaseSource(_Tree):
    """`source`: where a pinned base is fetched from (#139).

    Docker Hub rate-limits anonymous pulls, and a buildx container build
    pulls its FROM where nothing retries it (doppler-dsp/doppler#1982). So
    the base's manifest is probed under retry, and the build is told which
    registry answered.
    """

    def setUp(self) -> None:
        super().setUp()
        self.fake = self.root / "fake"
        self.fake.mkdir()
        (self.fake / "docker").write_text(_FAKE_DOCKER)
        (self.fake / "docker").chmod(0o755)

    def answers(self, ref: str, *outcomes: str) -> None:
        name = ref.replace("/", "_").replace(":", "_").replace("@", "_")
        (self.fake / name).write_text("\n".join(outcomes) + "\n")

    def asked(self) -> "list[str]":
        log = self.fake / "calls.log"
        return log.read_text().split() if log.exists() else []

    def source(self, ref: str = PINNED, registry: str = REG,
               mirror: str = MIRROR, cmd: str = "source"):
        env = {**os.environ, "CI_IMAGE_BASES": BASES,
               "PATH": f"{self.fake}:{os.environ['PATH']}",
               "FAKE_DOCKER_DIR": str(self.fake),
               "CI_IMAGE_BASE_REGISTRY": registry,
               "CI_IMAGE_BASE_MIRROR": mirror,
               "CI_IMAGE_PULL_ATTEMPTS": "3", "CI_IMAGE_PULL_DELAY": "0"}
        args = [cmd, ref] if cmd == "source" else [cmd, "--refresh"]
        return subprocess.run([sys.executable, str(SCRIPT), *args],
                              cwd=self.root, env=env, capture_output=True,
                              text=True)

    def test_unset_names_the_base_and_asks_no_registry(self):
        """An adopter without the setting makes no new call at all."""
        r = self.source(registry="", mirror="")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, PINNED))
        self.assertEqual(self.asked(), [])

    def test_a_registry_that_answers_is_the_source(self):
        self.answers(f"{REG}/{PINNED}", "ok")
        r = self.source()
        self.assertEqual(r.stdout.strip(), f"{REG}/{PINNED}", r.stderr)
        self.assertEqual(self.asked(), [f"{REG}/{PINNED}"])

    def test_a_rate_limit_is_retried_not_sent_to_the_mirror(self):
        self.answers(f"{REG}/{PINNED}", "429", "429", "ok")
        r = self.source()
        self.assertEqual(r.stdout.strip(), f"{REG}/{PINNED}", r.stderr)
        self.assertEqual(self.asked(), [f"{REG}/{PINNED}"] * 3)
        self.assertIn("retry 2/3", r.stderr)

    def test_a_quota_goes_to_the_mirror_at_once(self):
        """A volume quota outlasts any retry window (doppler#2256)."""
        self.answers(f"{REG}/{PINNED}", "quota")
        self.answers(f"{MIRROR}/{PINNED}", "ok")
        r = self.source()
        self.assertEqual(r.stdout.strip(), f"{MIRROR}/{PINNED}", r.stderr)
        self.assertEqual(self.asked(), [f"{REG}/{PINNED}", f"{MIRROR}/{PINNED}"])

    def test_retries_that_run_out_go_to_the_mirror(self):
        self.answers(f"{REG}/{PINNED}", "429")
        self.answers(f"{MIRROR}/{PINNED}", "ok")
        r = self.source()
        self.assertEqual(r.stdout.strip(), f"{MIRROR}/{PINNED}", r.stderr)
        self.assertEqual(self.asked().count(f"{REG}/{PINNED}"), 3)

    def test_a_missing_tag_fails_and_is_never_sent_to_the_mirror(self):
        """A tag the registry lacks is a typo, not an outage."""
        self.answers(f"{REG}/{PINNED}", "unknown")
        r = self.source()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertIn("manifest unknown", r.stderr)
        self.assertEqual(self.asked(), [f"{REG}/{PINNED}"])

    def test_with_no_mirror_an_unreachable_registry_fails(self):
        self.answers(f"{REG}/{PINNED}", "quota")
        r = self.source(mirror="")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")
        self.assertIn("CI_IMAGE_BASE_MIRROR is unset", r.stderr)

    def test_both_unreachable_fails(self):
        self.answers(f"{REG}/{PINNED}", "quota")
        self.answers(f"{MIRROR}/{PINNED}", "429")
        r = self.source()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")

    def test_an_image_with_a_slash_is_fetched_as_named(self):
        """Only official images live on the mirrors' library paths."""
        ref = f"quay.io/pypa/manylinux_2_28_x86_64@{D}"
        self.answers(ref, "ok")
        r = self.source(ref)
        self.assertEqual(r.stdout.strip(), ref, r.stderr)
        self.assertEqual(self.asked(), [ref])

    def test_a_refresh_pins_the_digest_registry_free(self):
        """The pin names the image, not where it was fetched: changing the
        registry owes no repin."""
        for b in BASES.split():
            self.answers(f"{REG}/{b}", "ok")
        (self.root / ".github" / "ci-images.env").write_text(
            "CI_JB_VERSION=v0.7.0\nCI_JB_SHA256=" + "b" * 64 + "\n")
        r = self.source(cmd="inputs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("CI_BASE_2404=ubuntu:24.04@sha256:" + "f" * 64,
                      r.stdout.splitlines())
        self.assertEqual(sorted(self.asked()),
                         sorted(f"{REG}/{b}" for b in BASES.split()))


class TestThePackagerDockerfile(unittest.TestCase):
    """The real vendored file: every input is a build ARG with no default."""

    def test_no_arg_has_a_default(self):
        text = (ROOT / "docker" / "packager.Dockerfile").read_text()
        args = [ln for ln in text.splitlines()
                if re.match(r"^\s*ARG\s", ln)]
        self.assertTrue(args, "the packager Dockerfile declares no ARGs")
        for ln in args:
            with self.subTest(arg=ln):
                self.assertNotIn("=", ln)

    def test_the_base_is_an_arg_never_a_literal_image(self):
        """The glibc floor is the base's: the Dockerfile must not pick one."""
        text = (ROOT / "docker" / "packager.Dockerfile").read_text()
        self.assertRegex(text, r"(?m)^FROM \$\{BASE\}$")
        self.assertNotRegex(text, r"(?m)^FROM (?!\$\{BASE\}$)")


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

    def test_no_syntax_directive(self):
        """`# syntax=` makes BuildKit fetch a frontend image from Docker Hub
        before it builds, anonymously and unretried (#139). Nothing here
        needs more than the built-in frontend."""
        self.assertNotRegex(self.text, r"(?im)^#\s*syntax\s*=")

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

    def test_a_branch_push_builds_only_when_the_pin_is_owed(self):
        """A release bump moves no source the image reads, so it builds
        nothing; a schedule or dispatch always builds (doppler#1765)."""
        # The condition may name the packager too (HAS_PACKAGER_IMAGE), so the
        # match is the push test, then the CI check, then the owed=false arm.
        self.assertRegex(
            self.text,
            r'(?s)"\$\{\{ github\.event_name \}\}" = push \] && '
            r'make -s ci-image-check\b.*?;\s+then\s+echo "owed=false"',
        )
        build = self.text[self.text.index("\n  build:"):]
        build = build[:build.index("\n  publish:")]
        self.assertIn("if: needs.resolve.outputs.owed == 'true'", build)

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

    def _run_unlanded_step(self, ls_rc: int, differs: bool) -> int:
        """Execute the step's real run: text with a stubbed git."""
        i = self.text.index("An unlanded repin keeps this run red")
        body = self.text[self.text.index("run: |", i) + len("run: |"):]
        lines = [ln[10:] if ln.startswith(" " * 10) else ln.strip()
                 for ln in body.splitlines()[1:]]
        script = "\n".join(lines)
        with tempfile.TemporaryDirectory() as tmp:
            stub = pathlib.Path(tmp) / "git"
            stub.write_text(
                "#!/bin/sh\n"
                'case "$1" in\n'
                f"  ls-remote) exit {ls_rc} ;;\n"
                f"  diff) exit {1 if differs else 0} ;;\n"
                "esac\nexit 0\n"
            )
            stub.chmod(0o755)
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}",
                   "DEFAULT": "main",
                   "GITHUB_STEP_SUMMARY": str(pathlib.Path(tmp) / "s")}
            return subprocess.run(["bash", "-c", script], env=env,
                                  capture_output=True).returncode

    def test_the_unlanded_step_reads_every_ls_remote_answer(self):
        cases = [
            (2, False, 0),    # no branch: nothing owed
            (0, False, 0),    # branch matches the default branch
            (0, True, 1),     # an unlanded repin: red
            (128, False, 1),  # cannot tell (network, auth): red, not green
        ]
        for rc, differs, want in cases:
            with self.subTest(ls_remote=rc, differs=differs):
                self.assertEqual(self._run_unlanded_step(rc, differs), want)

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

    def test_the_build_fetches_its_base_from_the_probed_registry(self):
        """The FROM is pulled inside BuildKit, where nothing retries it, so
        the build's BASE is what `ci-image-base` answered (#139)."""
        build = self.text[self.text.index("\n  build:"):]
        build = build[:build.index("\n  packager:")]
        self.assertIn('base_ref=$(make -s ci-image-base REF=', build)
        self.assertIn('--build-arg BASE="$base_ref"', build)

    def test_a_refresh_reads_digests_through_the_registry(self):
        for name in ("base_registry", "base_mirror"):
            self.assertIn(f"sed -n 's/^{name}=//p'", self.text)
        self.assertIn("export CI_IMAGE_BASE_REGISTRY CI_IMAGE_BASE_MIRROR",
                      self.text)


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
