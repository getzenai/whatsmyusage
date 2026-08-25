#!/usr/bin/env python3
"""Removes the `pBBk` record from a mounted disk image's .DS_Store.

Without this the window has no background picture, on macOS 26 at least.

A Finder window remembers its background twice: `icvp/backgroundImageAlias`,
an old-style alias, and `pBBk`, a modern bookmark. dmgbuild writes both, and
both are made while the image is still a scratch file in /tmp. The alias says
"the file .background.tiff at the root of the volume named X" and keeps working
wherever that volume turns up. The bookmark also pins the disk image it came
from — a temporary file that is gone by the time anyone downloads this — and
Finder reads the bookmark first, fails to resolve it, and stops.

Measured on macOS 26.5: identical image, `pBBk` removed, background appears.
Apple's own installers (the ChatGPT disk image, for one) carry the alias and no
bookmark at all.

Usage: dmg_drop_stale_bookmark.py /Volumes/Something
"""
import sys
from pathlib import Path

from ds_store import DSStore

store = Path(sys.argv[1]) / ".DS_Store"
with DSStore.open(str(store), "r+") as d:
    codes = {e.code for e in d if e.filename == "."}
    if b"pBBk" in codes:
        d.delete(".", b"pBBk")
        print(f"dropped the stale background bookmark from {store}")
    else:
        print(f"no background bookmark in {store}; nothing to do")
