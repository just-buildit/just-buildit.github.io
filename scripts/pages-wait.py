#!/usr/bin/env python3
"""Wait for GitHub Pages to publish a commit, then check what it serves.

Every adopter's drift gate fetches its vendored files from this site, so
two workflows ask one question after a push to main: does Pages serve what
this commit committed? ``Re-vendor adopters`` must not fan out before it
does (an adopter would vendor the stale copy), and CI's ``Serving matches
the repo`` is the same check from the repo's side.

Both used to poll the served files for a fixed ten minutes, and a Pages
deploy is not bounded by that: 69410b7's took 13.6 minutes, the waiter gave
up 2.5 minutes before Pages served the file, CI went red, and no adopter
got a re-vendor PR while every adopter's drift gate went red
(just-buildit.github.io#118). So this waits on the EVENT, not the clock:
the ``pages build and deployment`` run for the commit, until it completes.

``success``
    The served files are compared with the commit's, for a short grace
    while the CDN catches up. All equal: ``served=true``.
``cancelled`` or ``skipped``
    A newer push superseded the build, and the newer build publishes this
    commit's files too unless it changed them. So the wait follows the
    branch head to that build and compares again. Exiting here instead
    assumes a newer ``Re-vendor adopters`` run fans out, and a push that
    touches none of the vendored files (the mirror bot's) starts none.
    Cancelled with nothing newer on the branch is an error: nothing will
    publish the commit.
anything else
    The build failed: an error.

A served file that still differs once the newest build has finished is
explained only when a commit after this one changed it. That commit's own
runs answer for it, so this prints a notice and ``served=false``, and
``Re-vendor adopters`` leaves the fan-out to that run. Any other
difference is an error naming each file and both hashes.

A ``gh`` read that fails is named and waited past, never a verdict; one
refused for authorization (HTTP 401/403) cannot recover by waiting and is
an error at once. No completed build within ``--budget`` seconds is an
error saying what was last seen. A job's own ``timeout-minutes`` must sit
above the budget plus the grace, so this script, not the runner, is what
reports a slow Pages.

Usage::

    python3 scripts/pages-wait.py [--budget S] [--interval S] [--grace S]

Reads ``GITHUB_REPOSITORY``, ``GITHUB_SHA`` and ``GITHUB_REF_NAME`` (Actions
sets them) and compares the checkout's ``standard.mk``, ``scripts/*`` and
``github/*`` -- what adopters fetch -- with the site. Prints ``served=true``
or ``served=false`` and appends it to ``$GITHUB_OUTPUT`` when set; exits 1
on an error. ``gh`` needs ``GH_TOKEN`` with ``actions: read``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request
from typing import Any, Callable, Optional

#: The run GitHub creates for a branch-published Pages site. A ``dynamic/``
#: path is GitHub's own, so no repo workflow can share it.
PAGES_RUN = "dynamic/pages/pages-build-deployment"

SITE = "https://just-buildit.github.io"

#: What adopters fetch, as git pathspecs over the checkout: the same set
#: ``Re-vendor adopters`` is triggered by.
SERVED = ("standard.mk", "scripts/*", "github/*")

#: Conclusions that mean a newer push took the build's place.
SUPERSEDED = ("cancelled", "skipped")

#: Seconds: how long to wait for a completed build (13.6 minutes is the
#: slowest deploy measured, on 69410b7), how often to ask, and how long the
#: CDN may take to serve a finished deploy. A job running this needs a
#: ``timeout-minutes`` above BUDGET + GRACE; tests/test_pages_wait.py
#: holds both workflows to that.
BUDGET = 45 * 60
INTERVAL = 20
GRACE = 5 * 60


class Fail(Exception):
    """A loud outcome: the job goes red with this message."""


class Unreadable(Exception):
    """A read that returned no answer; waited past, never a verdict."""


def digest(data: bytes) -> str:
    """The sha256 of *data*, as hex.

    >>> digest(b"")[:12]
    'e3b0c44298fc'
    """
    return hashlib.sha256(data).hexdigest()


class GitHub:
    """The real answers: ``gh api`` for GitHub, HTTPS for the site.

    A fake with the same four methods drives :func:`wait` in the tests, so
    every decision there runs with no network and no real clock.
    """

    def __init__(self, repo: str, branch: str, site: str = SITE) -> None:
        self.repo = repo
        self.branch = branch
        self.site = site

    def _api(self, path: str) -> Any:
        r = subprocess.run(
            ["gh", "api", path], capture_output=True, text=True
        )
        if r.returncode != 0:
            err = r.stderr.strip() or f"gh exited {r.returncode}"
            if r.returncode == 4 or "HTTP 401" in err or "HTTP 403" in err:
                raise Fail(f"gh cannot read {path}: {err}")
            raise Unreadable(f"gh api {path}: {err}")
        try:
            return json.loads(r.stdout)
        except ValueError as e:
            raise Unreadable(f"gh api {path}: {e}") from e

    def pages_run(self, sha: str) -> Optional[tuple[str, str, str]]:
        """The newest Pages run for *sha*: ``(status, conclusion, url)``."""
        runs = self._api(
            f"repos/{self.repo}/actions/runs"
            f"?head_sha={sha}&event=dynamic&per_page=100"
        )["workflow_runs"]
        runs = [r for r in runs if r.get("path") == PAGES_RUN]
        if not runs:
            return None
        r = max(runs, key=lambda r: r["id"])
        return r["status"], r.get("conclusion") or "", r["html_url"]

    def head(self) -> str:
        """The branch's head commit, now."""
        ref = self._api(f"repos/{self.repo}/git/ref/heads/{self.branch}")
        return ref["object"]["sha"]

    def changed(self, base: str, head: str) -> set:
        """The paths ``base...head`` changes."""
        cmp = self._api(f"repos/{self.repo}/compare/{base}...{head}")
        return {f["filename"] for f in cmp.get("files", [])}

    def served(self, path: str) -> Optional[str]:
        """The digest of what the site serves at *path*; None if nothing.

        The plain URL, as an adopter's ``standard-update`` fetches it.
        """
        try:
            with urllib.request.urlopen(
                f"{self.site}/{path}", timeout=30
            ) as r:
                return digest(r.read())
        except OSError:  # URLError and HTTPError are both OSErrors
            return None


def committed(paths: "tuple[str, ...]" = SERVED) -> dict:
    """``{path: digest}`` for the checkout's tracked files in *paths*."""
    files = subprocess.run(
        ["git", "ls-files", "--", *paths],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split("\n")
    return {f: digest(pathlib.Path(f).read_bytes()) for f in files if f}


def wait(
    src: GitHub,
    sha: str,
    want: dict,
    budget: float,
    interval: float,
    grace: float,
    say: Callable[[str], None] = print,
    now: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> bool:
    """Wait for Pages to publish *sha*; True when it serves *want*.

    *want* maps each path to the digest this commit has for it. Returns
    False when a later commit changed a file that differs (its own runs
    answer); raises :class:`Fail` for every outcome that must go red.
    """
    deadline = now() + budget
    target = sha
    seen = ""
    last_error = ""

    def expire() -> None:
        if now() >= deadline:
            raise Fail(
                f"no answer from Pages within {budget:.0f}s: the build for "
                f"{target[:7]} was last seen {seen or 'absent'}"
                + (f" ({last_error})" if last_error else "")
            )

    def ask(fn: Callable[..., Any], *args: str) -> Any:
        """``fn(*args)``, waiting past a failed read until the deadline."""
        nonlocal last_error
        while True:
            try:
                return fn(*args)
            except Unreadable as e:
                last_error = str(e)
                say(f"no answer yet: {e}")
                expire()
                sleep(interval)

    while True:
        expire()
        run = ask(src.pages_run, target)
        state = "absent" if run is None else "/".join(filter(None, run[:2]))
        if state != seen:
            say(f"Pages build for {target[:7]}: {state}")
            seen = state
        if run is None or run[0] != "completed":
            sleep(interval)
            continue
        _, conclusion, url = run

        if conclusion in SUPERSEDED:
            head = ask(src.head)
            if head == target:
                raise Fail(
                    f"the Pages build for {target[:7]} was {conclusion} "
                    f"and nothing newer is on the branch to publish it: "
                    f"{url}"
                )
            say(
                f"::notice::the Pages build for {target[:7]} was "
                f"{conclusion}; following {head[:7]}, whose build "
                f"publishes this commit's files too unless it changed them"
            )
            target, seen = head, ""
            continue
        if conclusion != "success":
            raise Fail(
                f"the Pages build for {target[:7]} ended {conclusion}: {url}"
            )

        # Deployed. The CDN may take a moment to catch up.
        settle = min(now() + grace, deadline)
        while True:
            got = {p: src.served(p) for p in want}
            off = sorted(p for p in want if got[p] != want[p])
            if not off:
                say(f"Pages serves {sha[:7]}'s {len(want)} file(s)")
                return True
            if now() >= settle:
                break
            sleep(interval)

        head = ask(src.head)
        if head != target:
            say(
                f"{len(off)} file(s) differ, and {head[:7]} is newer than "
                f"{target[:7]}: following its build"
            )
            target, seen = head, ""
            continue
        if target != sha:
            moved = ask(src.changed, sha, target)
            if all(p in moved for p in off):
                say(
                    f"::notice::{', '.join(off)} changed after "
                    f"{sha[:7]}, by {target[:7]} or a commit before it; "
                    f"that commit's own runs answer for what Pages serves"
                )
                return False
        lines = [
            f"  {p}: committed {want[p][:12]}, served "
            f"{(got[p] or 'nothing')[:12]}"
            for p in off
        ]
        raise Fail(
            f"Pages finished {target[:7]} and serves something else:\n"
            + "\n".join(lines)
        )


def main(argv: "list[str] | None" = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--budget", type=float, default=BUDGET)
    ap.add_argument("--interval", type=float, default=INTERVAL)
    ap.add_argument("--grace", type=float, default=GRACE)
    a = ap.parse_args(argv)
    sha = os.environ["GITHUB_SHA"]
    src = GitHub(
        os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_REF_NAME"]
    )
    want = committed()
    print(f"waiting for Pages to publish {sha[:7]} ({len(want)} file(s))")
    try:
        ok = wait(src, sha, want, a.budget, a.interval, a.grace)
    except Fail as e:
        # A workflow command is one line; %0A is its newline.
        print(f"::error::{e}".replace("\n", "%0A"))
        return 1
    line = f"served={str(ok).lower()}"
    print(line)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
