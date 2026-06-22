#!/usr/bin/env python3
"""Generate a single-item Sparkle appcast for the ramon fork's GitHub Releases.

Unlike upstream's update_appcast_{tip,tag}.py (which target ghostty.org + a
commit-prefixed R2 layout and prepend to an existing feed), the fork publishes a
SINGLE continuous stream where each release uploads its own appcast.xml asset.
Sparkle's feed URL is `releases/latest/download/appcast.xml`, which always serves
the newest release's appcast, and update detection compares `sparkle:version`
(CFBundleVersion, a monotonic commit count) — so one newest item is sufficient.

Inputs (all via env unless noted):
  GHOSTTY_BUILD          monotonic build number -> <sparkle:version>
  GHOSTTY_COMMIT         short commit hash       -> <sparkle:shortVersionString>
  GHOSTTY_DMG_URL        absolute URL of the DMG on the GitHub release
  GHOSTTY_PUBDATE        RFC-822 date string (pass `date -R`/`-u` from the workflow;
                         we do NOT call date here so the output is reproducible)
  GHOSTTY_MIN_MACOS      minimum system version (default 13.0)
  SIGN_UPDATE_FILE       path to the `sign_update` output (default sign_update.txt)
  APPCAST_OUT            output path (default appcast.xml)

`sign_update` emits a line like:
  sparkle:edSignature="BASE64==" length="12345"
We copy those attributes verbatim onto the <enclosure>.
"""

import html
import os
import re
import sys


def fail(msg: str) -> "None":
    print(f"fork_appcast: {msg}", file=sys.stderr)
    sys.exit(1)


def require(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        fail(f"missing required env {name}")
    return v


def parse_sign_update(path: str) -> "dict[str, str]":
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        fail(f"cannot read {path}: {e}")
    attrs = dict(re.findall(r'([\w:]+)="([^"]*)"', text))
    if "sparkle:edSignature" not in attrs or "length" not in attrs:
        fail(f"sign_update output missing edSignature/length: {text!r}")
    return attrs


def main() -> "None":
    build = require("GHOSTTY_BUILD")
    commit = require("GHOSTTY_COMMIT")
    dmg_url = require("GHOSTTY_DMG_URL")
    pubdate = require("GHOSTTY_PUBDATE")
    min_macos = os.environ.get("GHOSTTY_MIN_MACOS", "13.0").strip() or "13.0"
    sign_file = os.environ.get("SIGN_UPDATE_FILE", "sign_update.txt")
    out = os.environ.get("APPCAST_OUT", "appcast.xml")

    if not build.isdigit():
        fail(f"GHOSTTY_BUILD must be a positive integer, got {build!r}")

    attrs = parse_sign_update(sign_file)
    ed_sig = attrs["sparkle:edSignature"]
    length = attrs["length"]

    # Every dynamic value is attribute-escaped; only build/commit/min_macos/length
    # are interpolated into text/attrs and all are escaped defensively.
    enclosure = (
        f'        <enclosure url="{html.escape(dmg_url, quote=True)}"\n'
        f'                   type="application/octet-stream"\n'
        f'                   sparkle:edSignature="{html.escape(ed_sig, quote=True)}"\n'
        f'                   length="{html.escape(length, quote=True)}" />'
    )

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ghostty (ramon)</title>
    <description>Auto-update feed for the ramon fork of Ghostty.</description>
    <language>en</language>
    <item>
      <title>Build {html.escape(build)} ({html.escape(commit)})</title>
      <pubDate>{html.escape(pubdate)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(commit)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_macos)}</sparkle:minimumSystemVersion>
{enclosure}
    </item>
  </channel>
</rss>
"""

    try:
        with open(out, "w", encoding="utf-8") as f:
            f.write(xml)
    except OSError as e:
        fail(f"cannot write {out}: {e}")
    print(f"fork_appcast: wrote {out} (build {build}, commit {commit})")


if __name__ == "__main__":
    main()
