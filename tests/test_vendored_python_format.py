"""Every vendored Python file is already in the org's ruff format.

An adopter's ``lint-ruff-format`` runs ``ruff format`` over its tree. The
vendored files are kept out of it by ``STD_RUFF_EXCLUDE`` (see
test_ruff_vendored.py), but that holds only while the adopter's
``standard.mk`` lists the file: a vendored script that reaches a repo
before, or without, the ``standard.mk`` naming it is formatted like the
repo's own code, and the repo's ``standard-check`` then fails on the
rewrite. A review of scripts/pipefail-readers.py measured exactly that
rewrite under mcp-store's settings: its single-quoted doctest inputs became
double-quoted.

So a vendored file is written in the form the org's formatter produces --
the ``[format]`` table of mcp-store's ``configs/ruff.toml``, the settings
every repo copies -- and the exclusion becomes a second line of defence
rather than the only one. The list is the one adopters vendor, read from
``make standard-files`` with every feature flag on, as the mypy job reads
it, so a newly vendored file is covered without being named here.

Needs a ruff on PATH; CI installs the pinned one (the changelog job). A
missing ruff is a failure, never a skip.
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

#: mcp-store configs/ruff.toml: top-level line-length and target-version,
#: and its [format] table. --isolated, so no config file here or above can
#: change what is checked.
FORMAT = [
    "--isolated",
    "--line-length",
    "79",
    "--target-version",
    "py39",
    "--config",
    'format.quote-style = "double"',
    "--config",
    'format.indent-style = "space"',
    "--config",
    "format.docstring-code-format = true",
    "--config",
    "format.docstring-code-line-length = 79",
]


def vendored_python() -> "list[str]":
    """Every .py/.pyi standard.mk vendors, with every feature flag on."""
    text = (ROOT / "standard.mk").read_text(encoding="utf-8")
    flags = sorted(set(re.findall(r"\bHAS_[A-Z_]+", text)))
    required = sorted(set(re.findall(r"_std_require,([A-Z_]+)", text)))
    with tempfile.TemporaryDirectory() as d:
        shutil.copy(ROOT / "standard.mk", d)
        pathlib.Path(d, "Makefile").write_text(
            "".join(f"{f} = 1\n" for f in flags)
            + "".join(f"{v} = x\n" for v in required)
            + "CLEAN_PATHS = dist/\ninclude standard.mk\n"
        )
        out = subprocess.run(
            ["make", "-s", "-C", d, "standard-files"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    return [f for f in out.split() if f.endswith((".py", ".pyi"))]


class VendoredPythonFormat(unittest.TestCase):
    def test_every_vendored_python_file_is_formatted(self) -> None:
        ruff = shutil.which("ruff")
        if ruff is None:
            raise RuntimeError(
                "ruff is not on PATH: this test runs the org's formatter "
                "over every vendored Python file. Install ruff (CI does)."
            )
        files = vendored_python()
        # A list that came back empty has checked nothing.
        self.assertIn("scripts/pipefail-readers.py", files)
        p = subprocess.run(
            [ruff, "format", *FORMAT, "--diff", *files],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            p.returncode,
            0,
            "a vendored file is not in the org's ruff format, so an "
            "adopter's lint-ruff-format can rewrite it and fail its "
            "standard-check; run `ruff format` with the settings in "
            "FORMAT over it:\n" + p.stdout + p.stderr,
        )


if __name__ == "__main__":
    unittest.main()
