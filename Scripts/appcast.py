#!/usr/bin/env python3
"""Put one release into an appcast, the feed Sparkle polls.

The feed starts as the empty skeleton in Scripts/appcast-template.xml and ends
up attached to the GitHub release as `appcast.xml`. The release job calls this
after Apple has notarised the build and `sign_update` has signed the archive,
so an item only ever appears for something a user could actually install.

Rewriting XML with a text template would be the obvious shortcut and a bad
one: an unescaped `&` in a release note produces a feed that no longer parses,
and every installed copy then reports an error instead of an update. This goes
through ElementTree, which escapes for us.

    appcast.py add --feed feed.xml --version 0.6.0 \
        --url https://…/WhatsMyUsage.zip \
        --signature 'sparkle:edSignature="…" length="123"' \
        --notes-file release-notes.md
"""

from __future__ import annotations

import argparse
import email.utils
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TEMPLATE = pathlib.Path(__file__).resolve().parent / "appcast-template.xml"
MINIMUM_SYSTEM_VERSION = "14.0"  # LSMinimumSystemVersion in make-app-bundle.sh


def html_from_notes(notes: str) -> str:
    """Turn the release notes into the little HTML Sparkle's pane renders.

    Sparkle shows <description> as HTML, and `semver.py notes` writes Markdown.
    Handing it over unconverted puts literal `###` and `-` in front of a user.
    This covers only what those notes contain — headings and bullets — and
    leaves anything else as a paragraph, because half-rendered Markdown is
    worse than none. ElementTree escapes the text, so a `&` in a commit
    subject cannot break the feed.
    """
    html: list[str] = []
    in_list = False
    for line in notes.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if in_list:
                html.append("</ul>")
                in_list = False
            html.append(f"<h3>{line.lstrip('#').strip()}</h3>")
        elif line.startswith(("- ", "* ")):
            if not in_list:
                html.append("<ul>")
                in_list = True
            html.append(f"<li>{line[2:].strip()}</li>")
        else:
            if in_list:
                html.append("</ul>")
                in_list = False
            html.append(f"<p>{line}</p>")
    if in_list:
        html.append("</ul>")
    return "".join(html)


def parse_signature(raw: str) -> tuple[str, str]:
    """Split `sign_update`'s output into the two enclosure attributes.

    Its exact shape is Sparkle's business and has changed before, so read it
    with a pattern instead of splitting on spaces, and refuse anything that
    does not carry both halves. A missing signature is not a smaller update,
    it is one Sparkle will reject on every machine.
    """
    signature = re.search(r'sparkle:edSignature="([^"]+)"', raw)
    length = re.search(r'length="(\d+)"', raw)
    if not signature or not length:
        raise SystemExit(f"error: cannot read edSignature and length from: {raw!r}")
    return signature.group(1), length.group(1)


def add(args: argparse.Namespace) -> int:
    ET.register_namespace("sparkle", SPARKLE)
    # Keep the comments. The header of this file explains what an item in it
    # means, and a round trip that silently drops it would take the warning
    # away from whoever reads the feed next.
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    feed = pathlib.Path(args.feed)
    # A missing feed is the normal case: the release job hands us a fresh copy
    # of the skeleton. Falling back to the skeleton keeps a hand-run honest too.
    tree = ET.parse(feed if feed.exists() else TEMPLATE, parser=parser)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("error: appcast has no <channel>")

    version = args.version
    # Rerunning the job must not offer the same version twice. Sparkle would
    # pick one of them and the feed would grow a duplicate every retry.
    for item in channel.findall("item"):
        existing = item.find(f"{{{SPARKLE}}}shortVersionString")
        if existing is not None and existing.text == version:
            channel.remove(item)

    signature, length = parse_signature(args.signature)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(
        email.utils.parsedate_to_datetime(args.date) if args.date
        else __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
    )
    ET.SubElement(item, "link").text = args.release_url
    if args.notes_file:
        notes = pathlib.Path(args.notes_file).read_text(encoding="utf-8").strip()
        if notes:
            ET.SubElement(item, "description").text = html_from_notes(notes)
    # shortVersionString is what a person reads; version is what Sparkle
    # compares. Both are the tag — see the comment in make-app-bundle.sh.
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = MINIMUM_SYSTEM_VERSION
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("type", "application/octet-stream")
    enclosure.set("length", length)
    enclosure.set(f"{{{SPARKLE}}}edSignature", signature)

    # Newest first. Sparkle does not require it, a human reading the file does.
    children = list(channel)
    first_item = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item, item)

    ET.indent(tree, space="  ")
    tree.write(feed, encoding="utf-8", xml_declaration=True)
    with feed.open("a", encoding="utf-8") as handle:
        handle.write("\n")
    print(f"added {version} to {feed}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    add_parser = sub.add_parser("add", help="add or replace one version")
    add_parser.add_argument("--feed", required=True, help="feed to write; created from the template if absent")
    add_parser.add_argument("--version", required=True)
    add_parser.add_argument("--url", required=True, help="download URL of the zip")
    add_parser.add_argument("--release-url", required=True, help="the release page")
    add_parser.add_argument("--signature", required=True, help="sign_update output")
    add_parser.add_argument("--notes-file")
    add_parser.add_argument("--date", help="RFC 2822 date; defaults to now")
    add_parser.set_defaults(func=add)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
