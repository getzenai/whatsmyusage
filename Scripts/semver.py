#!/usr/bin/env python3
"""Conventional Commits -> semantic version for whatsmyusage.

One parser, three consumers, so a title that passes the check is a title the
release job can read:

  * the PR title check (a squash merge makes the PR title the commit subject)
  * the release job (which commits since the last tag mean which bump)
  * `Scripts/make-app-bundle.sh` (marketing version of a local build)

Git tags are the only record of the released version. There is no VERSION file
to drift out of sync with them.

Commands:
  check-title <title>  validate one subject; exit 1 with the reason
  current              latest v<x.y.z> tag, or 0.0.0 when there is none
  next                 version the commits since that tag would release
  bump                 none | patch | minor | major
  notes                release notes for those commits, grouped by type
  selftest             run the parser's own cases

Below 1.0.0 a breaking change bumps the minor, not the major: a first `feat!:`
should not declare the product finished. The strict rule takes over by itself
once a tag reads 1.x.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass

# type -> (release level, release-notes heading). A type that releases nothing
# still has to be in here: an unknown type is a rejected title, and that is the
# point of the check.
TYPES: dict[str, tuple[str, str]] = {
    "feat": ("minor", "Features"),
    "fix": ("patch", "Fixes"),
    "perf": ("patch", "Performance"),
    "revert": ("patch", "Reverts"),
    "refactor": ("none", "Internal"),
    "docs": ("none", "Documentation"),
    "test": ("none", "Internal"),
    "build": ("none", "Internal"),
    "ci": ("none", "Internal"),
    "chore": ("none", "Internal"),
    "style": ("none", "Internal"),
}

LEVELS = ["none", "patch", "minor", "major"]

# `type(scope)!: subject`. The scope is optional, the `!` marks a breaking
# change. Anything else — no colon, a capitalised type, an empty subject — is
# not a Conventional Commit and is rejected rather than guessed at.
SUBJECT_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^()\n]+)\))?(?P<breaking>!)?: (?P<subject>\S.*)$"
)

# GitHub appends the PR number when it squashes. Strip it before parsing so the
# same string passes both before and after the merge.
PR_SUFFIX_RE = re.compile(r"\s*\(#\d+\)\s*$")

BREAKING_FOOTER_RE = re.compile(r"^BREAKING[ -]CHANGE:\s*\S", re.MULTILINE)

TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


@dataclass(frozen=True)
class Commit:
    type: str
    scope: str | None
    breaking: bool
    subject: str

    @property
    def level(self) -> str:
        if self.breaking:
            return "major"
        return TYPES[self.type][0]

    @property
    def line(self) -> str:
        return f"{self.scope}: {self.subject}" if self.scope else self.subject


class InvalidSubject(ValueError):
    pass


def parse_subject(raw: str) -> Commit:
    """Parse one commit subject. Raises InvalidSubject with a usable reason."""
    subject = PR_SUFFIX_RE.sub("", raw.strip())
    if not subject:
        raise InvalidSubject("the title is empty")

    match = SUBJECT_RE.match(subject)
    if match is None:
        raise InvalidSubject(
            f"{subject!r} is not `type(scope): subject`.\n"
            f"  Known types: {', '.join(sorted(TYPES))}.\n"
            "  The type is lower case, the colon is followed by one space, "
            "and `!` before the colon marks a breaking change."
        )

    kind = match.group("type")
    if kind not in TYPES:
        raise InvalidSubject(
            f"unknown type {kind!r}. Known types: {', '.join(sorted(TYPES))}."
        )

    return Commit(
        type=kind,
        scope=match.group("scope"),
        breaking=bool(match.group("breaking")),
        subject=match.group("subject"),
    )


def parse_message(message: str) -> Commit:
    """Parse a full commit message: subject line plus a BREAKING CHANGE footer."""
    lines = message.strip().splitlines()
    commit = parse_subject(lines[0] if lines else "")
    if not commit.breaking and BREAKING_FOOTER_RE.search(message):
        commit = Commit(commit.type, commit.scope, True, commit.subject)
    return commit


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def current_version() -> tuple[int, int, int]:
    """Highest v<x.y.z> tag. No tags means nothing has been released yet."""
    versions = []
    for tag in git("tag", "--list", "v*").splitlines():
        match = TAG_RE.match(tag.strip())
        if match:
            versions.append(tuple(int(part) for part in match.groups()))
    return max(versions, default=(0, 0, 0))  # type: ignore[return-value]


def commits_since(version: tuple[int, int, int]) -> list[Commit]:
    """Releasable commits on the current branch since that version's tag.

    A subject that does not parse is skipped, not fatal: history from before
    the convention exists, and one old commit must not block every release.
    """
    tag = "v%d.%d.%d" % version
    has_tag = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", tag + "^{}"],
        capture_output=True,
    ).returncode == 0
    revision_range = f"{tag}..HEAD" if has_tag else "HEAD"

    raw = git("log", revision_range, "--no-merges", "--format=%B%x00")
    commits = []
    for message in raw.split("\0"):
        if not message.strip():
            continue
        try:
            commits.append(parse_message(message))
        except InvalidSubject:
            continue
    return commits


def bump_level(commits: list[Commit], version: tuple[int, int, int]) -> str:
    level = max((c.level for c in commits), key=LEVELS.index, default="none")
    # Pre-1.0: a breaking change is a minor. See the module docstring.
    if level == "major" and version[0] == 0:
        return "minor"
    return level


def apply_bump(version: tuple[int, int, int], level: str) -> tuple[int, int, int]:
    major, minor, patch = version
    if level == "major":
        return (major + 1, 0, 0)
    if level == "minor":
        return (major, minor + 1, 0)
    if level == "patch":
        return (major, minor, patch + 1)
    return version


def release_notes(commits: list[Commit], version: tuple[int, int, int]) -> str:
    sections: dict[str, list[str]] = {}
    breaking = [c.line for c in commits if c.breaking]
    for commit in commits:
        if TYPES[commit.type][0] == "none" and not commit.breaking:
            continue
        sections.setdefault(TYPES[commit.type][1], []).append(commit.line)

    out = []
    if breaking:
        out.append("### Breaking changes\n")
        out += [f"- {line}" for line in breaking]
        out.append("")
    for heading in ("Features", "Fixes", "Performance", "Reverts"):
        if heading in sections:
            out.append(f"### {heading}\n")
            out += [f"- {line}" for line in sections[heading]]
            out.append("")
    if not out:
        out.append("No user-facing changes.")
    return "\n".join(out).strip() + "\n"


def selftest() -> int:
    def parses(title: str, **expected) -> None:
        commit = parse_subject(title)
        for key, value in expected.items():
            actual = getattr(commit, key)
            assert actual == value, f"{title!r}: {key} is {actual!r}, expected {value!r}"

    def rejects(title: str) -> None:
        try:
            parse_subject(title)
        except InvalidSubject:
            return
        raise AssertionError(f"{title!r} should have been rejected")

    parses("feat: show the reset voucher", type="feat", scope=None, breaking=False)
    parses("fix(cli): keep a stale number null", scope="cli", level="patch")
    parses("feat!: drop the old log schema", breaking=True, level="major")
    parses("feat(log)!: rekey the series", scope="log", breaking=True)
    # A squashed title carries the PR number; it must parse the same way.
    parses("feat: add achievements (#26)", subject="add achievements")
    parses("chore: bump the toolchain", level="none")

    rejects("")
    rejects("Add the landing page")           # the whole history before this change
    rejects("Feat: capitalised type")
    rejects("feat missing colon")
    rejects("feat:no space after the colon")
    rejects("feat: ")                          # empty subject
    rejects("wip: unknown type")

    # The footer is as breaking as the `!`.
    assert parse_message("fix: adjust the parser\n\nBREAKING CHANGE: drops v1 logs").breaking
    assert not parse_message("fix: adjust the parser\n\nBREAKING CHANGE follows later").breaking

    # Bumps, including the two that catch people out.
    feat = parse_subject("feat: a")
    fix = parse_subject("fix: a")
    docs = parse_subject("docs: a")
    breaks = parse_subject("feat!: a")
    assert bump_level([docs], (1, 2, 3)) == "none"
    assert bump_level([docs, fix], (1, 2, 3)) == "patch"
    assert bump_level([fix, feat], (1, 2, 3)) == "minor"
    assert bump_level([fix, breaks], (1, 2, 3)) == "major"
    assert bump_level([breaks], (0, 4, 0)) == "minor", "pre-1.0 breaking is a minor"
    assert bump_level([], (1, 0, 0)) == "none"

    assert apply_bump((1, 2, 3), "patch") == (1, 2, 4)
    assert apply_bump((1, 2, 3), "minor") == (1, 3, 0)
    assert apply_bump((1, 2, 3), "major") == (2, 0, 0)
    assert apply_bump((1, 2, 3), "none") == (1, 2, 3)

    notes = release_notes([feat, fix, docs, breaks], (1, 3, 0))
    assert "### Features" in notes and "### Fixes" in notes
    assert "### Breaking changes" in notes
    assert "docs" not in notes, "a docs commit is not a release note"
    assert release_notes([docs], (1, 2, 4)).startswith("No user-facing")

    print("selftest: ok")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]

    if command == "selftest":
        return selftest()

    if command == "check-title":
        if len(argv) != 3:
            print("usage: semver.py check-title <title>", file=sys.stderr)
            return 2
        try:
            commit = parse_subject(argv[2])
        except InvalidSubject as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        level = "major" if commit.breaking else TYPES[commit.type][0]
        print(f"ok: {commit.type} -> {level} release")
        return 0

    version = current_version()

    if command == "current":
        print("%d.%d.%d" % version)
        return 0

    commits = commits_since(version)

    if command == "bump":
        print(bump_level(commits, version))
        return 0
    if command == "next":
        print("%d.%d.%d" % apply_bump(version, bump_level(commits, version)))
        return 0
    if command == "notes":
        print(release_notes(commits, version), end="")
        return 0

    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
