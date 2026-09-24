#!/usr/bin/env python3
"""Changelog fragments: one file per entry, promoted once per release.

VENDORED VERBATIM from https://just-buildit.github.io/scripts/changelog.py
and checked by ``standard-check`` like ``standard.mk`` itself. Never edit it
in place; change canonical and re-vendor. Every repo-specific value arrives
as an argument from the ``HAS_CHANGELOG`` block of ``standard.mk``.

Why fragments
-------------
Every open pull request used to append to the top of ``## [Unreleased]``, so
each merge knocked every other open PR to CONFLICTING -- ``O(N^2)``
hand-resolutions, none about code, each restarting that PR's CI. doppler
measured it with twelve PRs in flight (2026-08-16), just-makeit with twenty
in one day (2026-09-23). It is a property of the layout, not of anyone's
discipline, so an entry is a FILE::

    changelog.d/<section>/<slug>.md

The directory IS the ``### <Section>`` heading it lands under, and the
content is the entry verbatim, starting with ``- ``. Two PRs touch two
files, and git has nothing to resolve.

Subcommands
-----------
``check BASE``
    The branch gate (``make changelog-check``). A branch that changes code
    must add a fragment; a hand-written ``[Unreleased]`` entry is refused,
    because that file is the churn; every fragment must be well-formed.
``sections BASE``
    ``make changelog-sections-check``. A section that shipped is history:
    no branch may change or delete one, or duplicate its heading.
``assemble [--version X.Y.Z] [--check]``
    ``make changelog-assemble``. Promote every fragment into
    ``[Unreleased]`` and delete it; with ``--version``, also rename
    ``[Unreleased]`` to the release. ``--check`` (``make
    changelog-assembled-check``) mutates nothing and exits 1 while any
    fragment is outstanding.

One parser serves all three. doppler's first version parsed
``[Unreleased]`` in awk for the guard and in Python for the assembler, and
just-makeit's section gate was a third; three readings of one file are three
chances to disagree about where a section ends.

Examples
--------
>>> text = "## [Unreleased]\\n\\n- a\\n\\n## [1.0] - 2026-01-01\\n\\n- b\\n"
>>> [s.label for s in sections(text)]
['Unreleased', '1.0']
>>> count_entries(unreleased_body(text))
1
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import re
import subprocess
from typing import Callable, Dict, List, NamedTuple, Optional, Tuple

#: Keep a Changelog's order, ``breaking`` first because a reader scanning a
#: release wants that news before anything else, and ``docs``, which three of
#: the four adopters already publish. A repo passes its own list with
#: ``--sections`` (``CHANGELOG_SECTIONS`` in the Makefile).
DEFAULT_SECTIONS = (
    "breaking added changed deprecated removed fixed security docs".split()
)

UNRELEASED = "Unreleased"
_HEADING = re.compile(r"^## \[([^\]]+)\](.*)$")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")

#: A release version as ``bump-version`` accepts it: no pre-release suffix,
#: because CMake and Cargo reject one.
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


class Section(NamedTuple):
    """One ``## [label]`` section: its heading line through the next ``## ``."""

    label: str
    text: str


def sections(text: str) -> List[Section]:
    """Every ``## [label]`` section of *text*, in file order.

    A section runs from its heading line up to the next ``## `` heading, so
    a changed date on the heading is an edit like a changed entry. Text
    above the first heading (the title, a preamble) belongs to no section.
    A list, not a dict: a duplicated heading must stay visible.

    >>> [s.label for s in sections("# T\\n## [Unreleased]\\n## [1.0]\\n- a\\n")]
    ['Unreleased', '1.0']
    >>> sections("## [1.0]\\n- a\\n## Notes\\n- b\\n")[0].text
    '## [1.0]\\n- a\\n'
    """
    out: List[Section] = []
    label: Optional[str] = None
    buf: List[str] = []
    for line in text.splitlines(keepends=True):
        m = _HEADING.match(line)
        if m or line.startswith("## "):
            if label is not None:
                out.append(Section(label, "".join(buf)))
            label, buf = (m.group(1), [line]) if m else (None, [])
        elif label is not None:
            buf.append(line)
    if label is not None:
        out.append(Section(label, "".join(buf)))
    return out


def unreleased_body(text: str) -> str:
    """The ``[Unreleased]`` section's text below its heading, or ``""``."""
    for s in sections(text):
        if s.label == UNRELEASED:
            return s.text.split("\n", 1)[1] if "\n" in s.text else ""
    return ""


def count_entries(body: str) -> int:
    """Top-level ``- `` entries in *body*.

    >>> count_entries("### Fixed\\n\\n- a\\n    more\\n- b\\n  - nested\\n")
    2
    """
    return sum(1 for line in body.splitlines() if line.startswith("- "))


# ── fragments ────────────────────────────────────────────────────────────────


def fragment_errors(
    root: pathlib.Path, frag_dir: str, section_names: List[str]
) -> List[str]:
    """Why each fragment under *frag_dir* would be promoted wrongly, if at all.

    The one validator: ``check`` runs it on every branch, ``assemble``
    refuses to write while it reports anything. A fragment must sit in a
    known section directory, be a Markdown file, start with ``- ``, and
    carry no ``### `` line -- the directory is its heading, and a heading in
    the body captures every fragment promoted after it (doppler 0.43.0
    published five ``changed/`` entries under **Removed** that way).
    """
    base = root / frag_dir
    if not base.is_dir():
        return []
    errs: List[str] = []
    for p in sorted(base.rglob("*")):
        if p.is_dir() or p.name == "README.md" or p.name == ".gitkeep":
            continue
        rel = p.relative_to(root)
        parts = p.relative_to(base).parts
        if len(parts) != 2 or parts[0] not in section_names:
            errs.append(
                f"{rel}: not in a section directory -- use "
                f"{frag_dir}/<{'|'.join(section_names)}>/<slug>.md"
            )
            continue
        if p.suffix != ".md":
            errs.append(f"{rel}: a fragment is a .md file")
            continue
        entry = p.read_text(encoding="utf-8").strip("\n")
        if not entry.startswith("- "):
            errs.append(
                f"{rel}: does not start with '- ' -- a fragment is the entry "
                "itself, verbatim"
            )
        for n, line in enumerate(entry.splitlines(), 1):
            if line.startswith("### ") or line.startswith("## "):
                errs.append(
                    f"{rel} line {n}: a heading ({line.strip()!r}). The "
                    "directory IS the heading; delete the line, or move the "
                    "file to the section it belongs under"
                )
    return errs


def fragments(
    root: pathlib.Path, frag_dir: str, section_names: List[str]
) -> Dict[str, List[pathlib.Path]]:
    """Every fragment, by section in *section_names* order, sorted by name.

    Sorted so the assembled order is a property of the tree, not of the
    order the filesystem returned.
    """
    found: Dict[str, List[pathlib.Path]] = {}
    for name in section_names:
        d = root / frag_dir / name
        files = sorted(p for p in d.glob("*.md") if p.name != "README.md")
        if files:
            found[name] = files
    return found


def title(name: str) -> str:
    """The ``###`` heading a section directory stands for.

    >>> title("fixed")
    'Fixed'
    """
    return name.capitalize()


def insert(body: str, name: str, entries: str, order: List[str]) -> str:
    """Put *entries* under ``### <Name>`` in *body*, creating it if absent.

    An existing heading is APPENDED to, so an entry already there keeps its
    place. A new heading goes above the first existing heading that *order*
    puts after it, else at the end.

    >>> insert("\\n### Fixed\\n\\n- f\\n", "added", "- a", ["added", "fixed"])
    '\\n\\n### Added\\n\\n- a\\n\\n### Fixed\\n\\n- f\\n'
    >>> insert("\\n### Fixed\\n\\n- f\\n", "fixed", "- g", ["fixed"])
    '\\n### Fixed\\n\\n- f\\n\\n- g\\n'
    """
    head = re.compile(rf"^### {re.escape(title(name))}\s*$", re.M)
    m = head.search(body)
    if m:
        nxt = re.compile(r"^### ", re.M).search(body, m.end())
        cut = nxt.start() if nxt else len(body)
        tail = body[cut:]
        return (
            body[:cut].rstrip("\n")
            + "\n\n"
            + entries
            + "\n"
            + ("\n" + tail if tail else "")
        )
    later = order[order.index(name) + 1 :] if name in order else []
    for other in later:
        m2 = re.compile(rf"^### {re.escape(title(other))}\s*$", re.M).search(
            body
        )
        if m2:
            return (
                body[: m2.start()].rstrip("\n")
                + f"\n\n### {title(name)}\n\n"
                + entries
                + "\n\n"
                + body[m2.start() :]
            )
    return body.rstrip("\n") + f"\n\n### {title(name)}\n\n" + entries + "\n"


def date_separator(text: str) -> str:
    """How this CHANGELOG separates a version from its date.

    Read from the newest released heading, because adopters differ
    (``## [0.6.0] - 2026-09-09`` in one, ``## [0.87.1] — 2026-09-23`` in
    another) and a release must not change a file's own convention. ``" - "``
    (Keep a Changelog) when there is nothing to read it from.

    >>> date_separator("## [Unreleased]\\n## [1.0] — 2026-01-01\\n")
    ' — '
    >>> date_separator("## [Unreleased]\\n")
    ' - '
    """
    for s in sections(text):
        if s.label == UNRELEASED:
            continue
        rest = _HEADING.match(s.text.split("\n", 1)[0])
        d = _DATE.search(rest.group(2)) if rest else None
        if d:
            return rest.group(2)[: d.start()]
    return " - "


def retitle(text: str, version: str, today: str) -> str:
    """Rename ``[Unreleased]`` to ``[version] <sep> today``, open a fresh one.

    ONE line is replaced, so every entry under the old heading stays where it
    is and becomes the release's body.

    >>> retitle("## [Unreleased]\\n\\n- a\\n", "1.2.3", "2026-01-01")
    '## [Unreleased]\\n\\n## [1.2.3] - 2026-01-01\\n\\n- a\\n'
    """
    if any(s.label == version for s in sections(text)):
        raise SystemExit(
            f"changelog: the CHANGELOG already has a ## [{version}] section.\n"
            "  Re-running would open a second one. Nothing was written."
        )
    m = re.search(r"^## \[Unreleased\][^\n]*", text, re.M)
    if not m:
        raise SystemExit("changelog: no '## [Unreleased]' heading")
    sep = date_separator(text)
    return (
        text[: m.start()]
        + f"## [Unreleased]\n\n## [{version}]{sep}{today}"
        + text[m.end() :]
    )


# ── git ──────────────────────────────────────────────────────────────────────


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=False
    )


def show(rev: str, path: str) -> str:
    """*path* at *rev*, or ``""`` where it does not exist."""
    r = git("show", f"{rev}:{path}")
    return r.stdout if r.returncode == 0 else ""


def merge_base(ref: str) -> str:
    r = git("merge-base", "HEAD", ref)
    if r.returncode != 0:
        raise SystemExit(
            f"changelog: no merge base with {ref} -- fetch it (CI needs "
            "fetch-depth: 0) or set CHANGELOG_BASE."
        )
    return r.stdout.strip()


# ── check ────────────────────────────────────────────────────────────────────


def _under(path: str, prefixes: List[str]) -> bool:
    """Is *path* inside one of *prefixes*, by whole path component?

    >>> _under("src/a.py", ["src"]), _under("srcfoo/a.py", ["src"])
    (True, False)
    """
    return any(
        path == p.rstrip("/") or path.startswith(p.rstrip("/") + "/")
        for p in prefixes
    )


def check(
    base_ref: str,
    code_paths: List[str],
    changelog: str,
    frag_dir: str,
    section_names: List[str],
) -> int:
    """The branch gate. Returns the exit code; prints why."""
    root = pathlib.Path(".")
    base = merge_base(base_ref)
    status = git("diff", "--name-status", "--no-renames", base, "HEAD")
    changed: List[Tuple[str, str]] = [
        (ln.split("\t", 1)[0], ln.split("\t", 1)[1])
        for ln in status.stdout.splitlines()
        if "\t" in ln
    ]
    dirty = git("status", "--porcelain", "--", *code_paths).stdout.strip()

    problems = fragment_errors(root, frag_dir, section_names)

    if not changed:
        # With no commits ahead the gate reads nothing -- and "inert" then
        # reads exactly like "checked, fine" while the work sits uncommitted.
        if dirty:
            problems.insert(
                0,
                "inert (no commits ahead of "
                f"{base_ref}), but the tree has uncommitted code changes -- "
                "commit, then run it again",
            )
        else:
            print(f"changelog-check: no commits ahead of {base_ref} -- inert")
    else:
        if dirty:
            print(
                "changelog-check: NOTE -- uncommitted code changes are not "
                "covered below; it reads the commits, not the working tree."
            )
        frag = frag_dir.rstrip("/") + "/"
        added = [
            p
            for s, p in changed
            if s == "A" and p.startswith(frag) and p.endswith(".md")
            and not p.endswith("README.md")
        ]
        consumed = any(
            s == "D" and p.startswith(frag) and p.endswith(".md")
            for s, p in changed
        )
        base_n = count_entries(unreleased_body(show(base, changelog)))
        head_n = count_entries(unreleased_body(show("HEAD", changelog)))
        if head_n > base_n and not consumed:
            problems.append(
                f"{changelog} [Unreleased] gained an entry by hand "
                f"({base_n} at the base, {head_n} now). That is the line every "
                "other open PR appends to; write it as "
                f"{frag}<section>/<slug>.md instead and revert the hunk -- "
                "`make changelog-assemble` writes that file at release time"
            )
        code = [p for _, p in changed if _under(p, code_paths)]
        if code and not added and not consumed:
            problems.append(
                f"{len(code)} code file(s) changed and no fragment added "
                f"under {frag} -- write one naming what changed:\n    "
                + "\n    ".join(code[:10])
            )
        if not problems:
            why = (
                "assembled"
                if consumed
                else f"{len(added)} fragment(s)" if added else "no code changes"
            )
            print(f"changelog-check: OK ({why})")

    if problems:
        print("changelog-check: FAIL")
        for p in problems:
            print(f"  - {p}")
        print(
            f"\n  A fragment: {frag_dir}/<{'|'.join(section_names)}>/<slug>.md,"
            "\n  the entry verbatim, starting with '- '. Why it is a file and"
            "\n  not a line: the header of scripts/changelog.py."
        )
        return 1
    return 0


# ── sections ─────────────────────────────────────────────────────────────────


def released_edits(
    base: str,
    head: str,
    shipped: Callable[[str], Optional[str]] = lambda label: None,
) -> List[Tuple[str, str]]:
    """Released sections of *base* that *head* changed, removed or duplicated.

    Returns ``(label, "changed" | "removed" | "duplicated")`` pairs.
    ``[Unreleased]`` is exempt, and so is a section *base* did not have: a
    new section is the branch's own, which is what lets a release branch
    rename ``[Unreleased]`` with no carve-out for its name. A changed section
    is also exempt when *head* restores it to ``shipped(label)`` -- the
    section as its release tag carried it, the one correction with no
    judgement in it.

    A heading *head* repeats and *base* did not is refused whatever it holds:
    one copy can match history while the other carries the edit (a
    hand-merge that duplicated ``## [0.87.1]`` passed a dict-keyed version
    of this check, just-makeit#1526).

    >>> old = "## [Unreleased]\\n\\n## [1.0]\\n\\n- one\\n"
    >>> released_edits(old, old + "- new\\n")
    [('1.0', 'changed')]
    >>> released_edits(old, old.replace("## [Unreleased]\\n",
    ...                                 "## [Unreleased]\\n\\n## [1.1]\\n"))
    []
    >>> released_edits(old, old.replace("## [1.0]\\n", "## [1.0]\\n\\n## [1.0]\\n"))
    [('1.0', 'duplicated')]
    >>> released_edits(old + "- new\\n", old, {"1.0": "## [1.0]\\n\\n- one\\n"}.get)
    []
    """
    before = sections(base)
    after = sections(head)
    before_labels = [s.label for s in before]
    after_map: Dict[str, List[str]] = {}
    for s in after:
        after_map.setdefault(s.label, []).append(s.text)
    out: List[Tuple[str, str]] = []
    for s in before:
        if s.label == UNRELEASED:
            continue
        texts = after_map.get(s.label)
        if not texts:
            out.append((s.label, "removed"))
        elif len(texts) > 1 and before_labels.count(s.label) == 1:
            out.append((s.label, "duplicated"))
        elif texts[0] != s.text and texts[0] != shipped(s.label):
            out.append((s.label, "changed"))
    for label, texts in after_map.items():
        if (
            len(texts) > 1
            and label not in before_labels
            and (label, "duplicated") not in out
        ):
            out.append((label, "duplicated"))
    return out


def sections_check(base_ref: str, changelog: str) -> int:
    base = merge_base(base_ref)
    edits = released_edits(
        show(base, changelog),
        show("HEAD", changelog),
        lambda label: next(
            (
                s.text
                for s in sections(show(f"v{label}", changelog))
                if s.label == label
            ),
            None,
        ),
    )
    if not edits:
        print(
            "changelog-sections-check: no released section edited since "
            f"{base[:12]}"
        )
        return 0
    print(f"changelog-sections-check: {changelog} sections that shipped:")
    for label, how in edits:
        print(f"  ## [{label}]  ({how})")
    print(
        "\n  A released section is history. Put the entry in a fragment so"
        " the next\n  release carries it. The one edit allowed is restoring a"
        " section to what\n  its v<version> tag shipped."
    )
    return 1


# ── assemble ─────────────────────────────────────────────────────────────────


def assemble(
    changelog: str,
    frag_dir: str,
    section_names: List[str],
    version: str = "",
    check_only: bool = False,
    today: Optional[str] = None,
) -> int:
    root = pathlib.Path(".")
    errs = fragment_errors(root, frag_dir, section_names)
    if errs:
        print("changelog-assemble: refusing -- malformed fragment(s):")
        for e in errs:
            print(f"  - {e}")
        return 1
    found = fragments(root, frag_dir, section_names)
    total = sum(len(v) for v in found.values())

    if check_only:
        if not total:
            print("changelog-assembled-check: no fragments outstanding")
            return 0
        print(
            f"changelog-assembled-check: {total} fragment(s) not yet in "
            f"{changelog} -- `make changelog-assemble` first:"
        )
        for files in found.values():
            for f in files:
                print(f"  {f.as_posix()}")
        return 1

    path = root / changelog
    text = path.read_text(encoding="utf-8")
    if total:
        m = re.search(r"^## \[Unreleased\][^\n]*\n?", text, re.M)
        if not m:
            raise SystemExit(f"changelog: no '## [Unreleased]' in {changelog}")
        nxt = re.compile(r"^## ", re.M).search(text, m.end())
        start, end = m.end(), (nxt.start() if nxt else len(text))
        body = text[start:end]
        for name, files in found.items():
            chunk = "\n\n".join(
                f.read_text(encoding="utf-8").strip("\n") for f in files
            )
            body = insert(body, name, chunk, section_names)
        # One blank line under the heading and one above the next section,
        # whatever the inserts left: an empty [Unreleased] is a lone "\n",
        # and an insert into it would otherwise open with two.
        body = "\n" + body.strip("\n") + ("\n\n" if nxt else "\n")
        text = text[:start] + body + text[end:]
    if version:
        text = retitle(
            text, version, today or datetime.date.today().isoformat()
        )
    path.write_text(text, encoding="utf-8")
    for files in found.values():
        for f in files:
            f.unlink()
    print(
        f"changelog-assemble: promoted {total} fragment(s)"
        + (f", [Unreleased] -> [{version}]" if version else "")
    )
    for name, files in found.items():
        print(f"  ### {title(name)}: {len(files)}")
    return 0


# ── cli ──────────────────────────────────────────────────────────────────────


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="changelog.py", description=__doc__.split("\n\n")[0]
    )
    ap.add_argument("--file", default="CHANGELOG.md")
    ap.add_argument("--dir", default="changelog.d")
    ap.add_argument(
        "--sections",
        default=" ".join(DEFAULT_SECTIONS),
        help="section directories, in the order they are published",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="the branch gate")
    c.add_argument("base")
    c.add_argument("code_paths", nargs="+")
    s = sub.add_parser("sections", help="no released section is edited")
    s.add_argument("base")
    a = sub.add_parser("assemble", help="promote fragments")
    a.add_argument("--version", default="", metavar="X.Y.Z")
    a.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)
    names = args.sections.split()

    top = git("rev-parse", "--show-toplevel")
    if top.returncode == 0:
        os.chdir(top.stdout.strip())

    if args.cmd == "check":
        return check(args.base, args.code_paths, args.file, args.dir, names)
    if args.cmd == "sections":
        return sections_check(args.base, args.file)
    if args.check and args.version:
        raise SystemExit(
            "changelog: --check and --version are opposites; --check mutates "
            "nothing."
        )
    if args.version and not VERSION_RE.match(args.version):
        raise SystemExit(
            f"changelog: --version {args.version!r} is not X.Y.Z (a "
            "pre-release suffix is refused, as bump-version refuses it)"
        )
    return assemble(args.file, args.dir, names, args.version, args.check)


if __name__ == "__main__":
    raise SystemExit(main())
