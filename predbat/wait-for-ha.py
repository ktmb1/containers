"""Wait for Home Assistant to answer before starting Predbat.

Predbat checks Home Assistant exactly once, at startup: HAInterface.initialize()
calls /api/services, and if that fails it logs "Unable to connect directly to
Home Assistant", marks the interface as failed and never tries it again (the
"ha" component is can_restart: False). Startup does not stop there, though.
Components.start() then waits up to 240s for each component that needs the
interface - HAHistory first - before the missing interface finally surfaces as
an exception, so the process sits for many minutes with no web UI and no Home
Assistant connection, logging "HAHistory: No HAInterface available", until the
liveness probe kills it.

That is not an edge case here. Predbat and Home Assistant are both single
replicas on a three-node cluster, so any node drain that moves Home Assistant
hits it one of two ways:

- Predbat is running when Home Assistant goes away. Its websocket gives up
  after ten reconnects, it exits, and the container restarts while Home
  Assistant is still coming back.
- Both are evicted from the same node, and Predbat's new pod starts first.

Either way Predbat starts into an unreachable Home Assistant. On the
2026-09-30 Talos roll this cost 7-8 minutes of battery control, twice.

So this runs as the entrypoint on every container start - a restart included,
which an init container would not cover - and only execs Predbat once
/api/services returns the same non-empty list Predbat's own check needs. It
does not time out: how long to wait for Home Assistant is the startup probe's
decision, not this script's.

The configuration is read from the same file Predbat reads
($PREDBAT_APPS_FILE, else ./apps.yaml). If it names no ha_url/ha_key - the
add-on style SUPERVISOR_TOKEN setup, or a !secret reference this script does
not resolve - there is nothing to wait for and Predbat starts immediately.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import yaml

PREDBAT = "/opt/predbat/hass.py"


class TagTolerantLoader(yaml.SafeLoader):
    """SafeLoader that reads any tag (!secret, !env_var ...) as null instead of failing."""


TagTolerantLoader.add_multi_constructor("!", lambda _loader, _suffix, _node: None)


def log(msg):
    print("wait-for-ha: {}".format(msg), flush=True)


def ha_settings():
    """Return (ha_url, ha_key) from apps.yaml, or (None, None) if there is nothing to wait for."""
    path = os.path.abspath(os.getenv("PREDBAT_APPS_FILE", "apps.yaml"))
    try:
        with open(path) as f:
            config = yaml.load(f, Loader=TagTolerantLoader) or {}
    except (OSError, yaml.YAMLError) as e:
        log("cannot read {} ({}), not waiting".format(path, e))
        return None, None

    for section in config.values() if isinstance(config, dict) else []:
        if isinstance(section, dict) and section.get("ha_url") and section.get("ha_key"):
            return str(section["ha_url"]).rstrip("/"), str(section["ha_key"])
    return None, None


def services_ready(url, key):
    """True when /api/services returns a non-empty list - the test HAInterface.initialize() applies."""
    request = urllib.request.Request(url + "/api/services", headers={"Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return bool(json.loads(response.read())), "HTTP {}".format(response.status)
    except urllib.error.HTTPError as e:
        # 401/403 means Home Assistant is up and the token is wrong. Waiting will not fix that,
        # and Predbat reports it far better than this script can, so let it start.
        if e.code in (401, 403):
            return True, "HTTP {} (token rejected - starting Predbat to report it)".format(e.code)
        return False, "HTTP {}".format(e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        return False, str(getattr(e, "reason", e))


def main():
    url, key = ha_settings()
    if url:
        delay = 2
        attempt = 0
        while True:
            attempt += 1
            ready, detail = services_ready(url, key)
            if ready:
                log("Home Assistant at {} is answering ({}), starting Predbat".format(url, detail))
                break
            log("Home Assistant at {} not ready ({}), attempt {}, retrying in {}s".format(url, detail, attempt, delay))
            time.sleep(delay)
            delay = min(delay * 2, 10)
    else:
        log("no ha_url/ha_key in apps.yaml, starting Predbat without waiting")

    # exec, not a child process: Predbat stays PID 1 and receives the kubelet's SIGTERM itself.
    os.execv(sys.executable, [sys.executable, PREDBAT] + sys.argv[1:])


if __name__ == "__main__":
    main()
