#!/usr/bin/env python3
"""Route Predbat's log files through $PREDBAT_LOG_DIR.

Predbat opens, rotates and serves its logs by bare relative filename, so they
land in the working directory -- which is also where its state lives
(predbat_config.json, the ML .npz models, cache/). On Kubernetes that directory
is a replicated PVC, and the logs are the bulk of it: on the Home Assistant
addon this replaces, 95MiB of predbat.log + predbat.1-9.log against 56MiB of
real state. Replicating a rotating debug log across DRBD peers is waste.

This cannot be fixed from outside the code:

  * A symlink farm does not survive rotation. os.rename("predbat.log",
    "predbat.1.log") renames the *symlink*, and the open("predbat.log", "w")
    that follows then creates a real file on the PVC -- so logs silently
    migrate back onto it after the first 10MiB. Verified, not assumed.
  * Pointing the CWD at the log directory would move the *state* off the PVC
    instead: only apps.yaml is relocatable (PREDBAT_APPS_FILE); the config
    JSON, the ML models and cache/ are all opened by bare relative name.

So the log path has to become configurable in the code. With PREDBAT_LOG_DIR
unset every path is byte-identical to upstream, which is what makes this safe
to carry across version bumps.

Each edit is asserted rather than best-effort: if upstream restructures its
logging, the build fails here with the site that no longer matches, instead of
producing an image that quietly writes logs back onto the PVC.
"""

import pathlib
import sys

HELPER = '''

def _predbat_log_path(filename):
    """
    Resolve a log filename against PREDBAT_LOG_DIR.

    Unset -- the upstream default -- returns the bare filename, so the log
    stays in the working directory and behaviour is unchanged.
    """
    log_dir = os.getenv("PREDBAT_LOG_DIR")
    return os.path.join(log_dir, filename) if log_dir else filename

'''

# (file, old, new, expected occurrences)
EDITS = [
    # --- hass.py: open and rotate -------------------------------------------
    (
        "hass.py",
        'self.logfile = open("predbat.log", "a")',
        'self.logfile = open(_predbat_log_path("predbat.log"), "a")',
        1,
    ),
    (
        "hass.py",
        'self.logfile = open("predbat.log", "w")',
        'self.logfile = open(_predbat_log_path("predbat.log"), "w")',
        1,
    ),
    (
        "hass.py",
        'os.rename("predbat.log", "predbat.1.log")',
        'os.rename(_predbat_log_path("predbat.log"), _predbat_log_path("predbat.1.log"))',
        1,
    ),
    (
        "hass.py",
        'filename = "predbat." + format(num_logs) + ".log"',
        'filename = _predbat_log_path("predbat." + format(num_logs) + ".log")',
        1,
    ),
    (
        "hass.py",
        'newfile = "predbat." + format(num_logs + 1) + ".log"',
        'newfile = _predbat_log_path("predbat." + format(num_logs + 1) + ".log")',
        1,
    ),
    # --- web.py: the UI reads the same files back ---------------------------
    # Without these the "Log" tab and the predbat.log download silently show
    # nothing once the files move, which looks like Predbat has stopped
    # logging rather than like a path problem.
    # v8.53.5 replaced web.py's two inline literals with read_predbat_log()
    # in utils.py, defaulting to these module constants. Patching them here
    # covers every caller at once - the /api/log page and the get_log MCP
    # tool - instead of each call site.
    (
        "utils.py",
        'PREDBAT_LOG_FILE = "predbat.log"',
        'PREDBAT_LOG_FILE = _predbat_log_path("predbat.log")',
        1,
    ),
    (
        "utils.py",
        'PREDBAT_LOG_FILE_PREV = "predbat.1.log"',
        'PREDBAT_LOG_FILE_PREV = _predbat_log_path("predbat.1.log")',
        1,
    ),
    (
        "web.py",
        'html_file_load("predbat.1.log", also_file="predbat.log", as_file="predbat.log")',
        'html_file_load(_predbat_log_path("predbat.1.log"), also_file=_predbat_log_path("predbat.log"), as_file="predbat.log")',
        1,
    ),
]


def main(root):
    root = pathlib.Path(root)

    # The helper lives in hass.py; web.py imports it. hass.py is the entry
    # point and already imports web, so web must not import hass at module
    # scope -- a late import inside the accessor would be needed otherwise.
    hass = root / "hass.py"
    text = hass.read_text()
    if "_predbat_log_path" in text:
        sys.exit("ERROR: hass.py already defines _predbat_log_path; patch is stale.")

    # Insert after the import block, before the first class or def, so the
    # helper is defined before anything that calls it.
    anchor = "\nclass "
    index = text.find(anchor)
    if index == -1:
        sys.exit("ERROR: could not find a class definition in hass.py to anchor the helper.")
    text = text[:index] + HELPER + text[index:]
    hass.write_text(text)

    # web.py needs the helper too; import it from hass would be circular, so
    # define an identical private copy there.
    web = root / "web.py"
    web_text = web.read_text()
    web_index = web_text.find(anchor)
    if web_index == -1:
        sys.exit("ERROR: could not find a class definition in web.py to anchor the helper.")
    web.write_text(web_text[:web_index] + HELPER + web_text[web_index:])

    # utils.py holds PREDBAT_LOG_FILE / _PREV since v8.53.5, and everything
    # (read_predbat_log, the get_log MCP tool) resolves through them.
    #
    # The helper must be defined ABOVE those constants, not before the first
    # def like the other two files: the constants are module-level and call
    # the helper at import time, so anchoring on "\ndef " - the first def is
    # ~100 lines below them - would raise NameError on import.
    utils = root / "utils.py"
    utils_text = utils.read_text()
    utils_anchor = "PREDBAT_LOG_FILE = "
    utils_index = utils_text.find(utils_anchor)
    if utils_index == -1:
        sys.exit("ERROR: could not find PREDBAT_LOG_FILE in utils.py to anchor the helper.")
    utils.write_text(utils_text[:utils_index] + HELPER.lstrip("\n") + utils_text[utils_index:])

    for name, old, new, expected in EDITS:
        path = root / name
        body = path.read_text()
        found = body.count(old)
        if found != expected:
            sys.exit(
                f"ERROR: {name}: expected {expected} occurrence(s) of:\n"
                f"  {old}\n"
                f"but found {found}. Upstream has changed its logging; review "
                f"patch-log-dir.py against this release before bumping."
            )
        path.write_text(body.replace(old, new))
        print(f"  patched {name}: {old}")

    # Nothing may still reference a bare log filename, or that site writes to
    # the PVC while every other one writes to the log directory.
    for name in ("hass.py", "web.py", "utils.py"):
        body = (root / name).read_text()
        for line_no, line in enumerate(body.splitlines(), 1):
            if "_predbat_log_path" in line or "def " in line:
                continue
            if '"predbat.log"' in line or '"predbat.1.log"' in line:
                # as_file= is a download filename, not a path on disk.
                if "as_file=" in line:
                    continue
                sys.exit(f"ERROR: {name}:{line_no} still uses a bare log path:\n  {line.strip()}")

    print("Log paths now honour PREDBAT_LOG_DIR.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
