#!/usr/bin/env python3
"""Reads the window settings out of a mounted disk image and fails on nonsense.

Everything here is invisible until someone downloads the thing: a disk image
with the right files in it still opens as a blank window if the .DS_Store is
wrong, and nothing logs a complaint.

Usage: dmg_check_window.py /Volumes/Something
"""
import sys
from pathlib import Path

from ds_store import DSStore

mount = Path(sys.argv[1])
problems = []

for name in ("WhatsMyUsage.app", "Applications", ".background.tiff"):
    if not (mount / name).exists():
        problems.append(f"{name} is not on the volume")
if (mount / "Applications").resolve() != Path("/Applications"):
    problems.append("Applications is not an alias to /Applications")

with DSStore.open(str(mount / ".DS_Store"), "r") as store:
    entries = {(e.filename, e.code) for e in store}

# See Scripts/dmg_drop_stale_bookmark.py: this record shadows the background.
if (".", b"pBBk") in entries:
    problems.append("the stale background bookmark survived")
for name in ("WhatsMyUsage.app", "Applications"):
    if (name, b"Iloc") not in entries:
        problems.append(f"{name} has no icon position; the window would arrange itself")

if problems:
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    sys.exit(1)
print("window settings look right")
