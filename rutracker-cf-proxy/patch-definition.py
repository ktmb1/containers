"""Cap RuTracker search keywords in the bundled Prowlarr definition.

Adds one Cardigann keywords filter after upstream's own (which strip Sonarr's
S01E02 and turn punctuation into spaces): keep the longest run of whole words
that fits in 90 characters.

Why 90: measured against RuTracker through Prowlarr on 2026-11-17, with the
same book's title and subtitle. Every whole-word query of 98 characters or
fewer found it; queries of 102, 104, 111 and ~120 found nothing, and one of
108 did - so past ~100 the result depends on where RuTracker cuts, and the
only safe side is below 100. 90 leaves room, and still keeps a title plus the
start of its subtitle, which is what identifies a book.

Cardigann has no truncate filter, so this is a re_replace. `(?=\\s|$)` makes
the cut land between words: RuTracker matches whole words only, and a
half-word ("семе") at the end matches nothing. A single word over 90 cannot
match the pattern and passes through unchanged.

Fails the build, rather than shipping an unpatched definition, if upstream's
filter block no longer looks the way this expects.
"""

import sys
from pathlib import Path

import rutracker_proxy

PATH = Path(rutracker_proxy.__file__).parent / "definitions" / "rutracker-proxy.yml"

# Upstream's punctuation filter and the trim that closes keywordsfilters.
ANCHOR = """\
    - name: re_replace
      args: ['[^\\p{L}\\p{N}]+', " "]
    - name: trim
"""

ADDED = """\
    # ktmb1/containers: RuTracker returns nothing for queries of ~100+
    # characters. Keep whole words up to 90. See patch-definition.py.
    - name: re_replace
      args: ['^(.{1,90})(?=\\s|$).*$', "$1"]
    - name: trim
"""

MARKER = "ktmb1/containers:"


def main() -> int:
    text = PATH.read_text("utf-8")
    if MARKER in text:
        print(f"{PATH}: already patched", file=sys.stderr)
        return 1
    count = text.count(ANCHOR)
    if count != 1:
        print(f"{PATH}: expected the keywordsfilters anchor once, found {count}", file=sys.stderr)
        return 1
    # The anchor must sit inside keywordsfilters, not some other filter list.
    head = text[: text.index(ANCHOR)]
    if head.rfind("keywordsfilters:") < head.rfind("\n  rows:"):
        print(f"{PATH}: anchor is not inside keywordsfilters", file=sys.stderr)
        return 1
    PATH.write_text(text.replace(ANCHOR, ANCHOR + ADDED), "utf-8")
    print(f"{PATH}: keyword cap added")
    return 0


if __name__ == "__main__":
    sys.exit(main())
