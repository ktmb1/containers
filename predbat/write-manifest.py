#!/usr/bin/env python3
"""Write the manifest.yaml Predbat validates its own install against.

Predbat ships a self-check: on every start it compares the files next to
hass.py against manifest.yaml (name, size, sha1). The release tarball does not
contain that manifest -- it is produced by Predbat's own GitHub downloader, the
install path this image deliberately replaces -- so without one Predbat calls
the GitHub contents API on *every* start to rebuild it, then fails to write it
because /opt/predbat is root-owned and the container runs unprivileged:

    Warn: Manifest file /opt/predbat/manifest.yaml is missing, bypassing checks...
    Fetching directory listing from https://api.github.com/...
    Error: Failed to write manifest: [Errno 13] Permission denied

That is an unauthenticated GitHub API call on every pod start (subject to a
60/hour/IP rate limit shared by everything else leaving this network), plus a
recurring error line that looks like a fault. Generating the manifest here
removes the runtime dependency entirely.

It is generated from the files actually in the image rather than copied from
upstream, which matters because the image is not a byte-identical copy of the
tarball: the non-amd64 prediction kernels are deleted, and hass.py and web.py
are patched for PREDBAT_LOG_DIR. An upstream manifest would report the deleted
kernels as missing files (a hard validation failure) and the patched pair as
size and SHA mismatches on every start.
"""

import hashlib
import os
import sys

import yaml


def git_blob_sha1(path):
    """GitHub's contents API reports a git blob SHA, not a plain file SHA1."""
    with open(path, "rb") as handle:
        data = handle.read()
    header = b"blob %d\0" % len(data)
    return hashlib.sha1(header + data).hexdigest()  # noqa: S324 - git's format, not a security check


def main(root):
    entries = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if not os.path.isfile(path) or name == "manifest.yaml":
            continue
        entries.append(
            {
                "name": name,
                "size": os.path.getsize(path),
                "sha": git_blob_sha1(path),
            }
        )

    if not entries:
        sys.exit("ERROR: no files found in {}; refusing to write an empty manifest.".format(root))

    with open(os.path.join(root, "manifest.yaml"), "w") as handle:
        yaml.dump(entries, handle, default_flow_style=False, sort_keys=False)

    print("Wrote manifest.yaml for {} files".format(len(entries)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
