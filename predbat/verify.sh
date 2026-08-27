#!/usr/bin/env bash
# Verify a built Predbat image starts, serves its UI, and keeps its logs off
# the state volume.
#
# A Predbat image that builds proves very little. The whole point of this image
# is the log redirection, and the failure mode it guards against is silent: if
# PREDBAT_LOG_DIR stops being honoured anywhere - one missed call site, an
# upstream refactor the patch script did not catch - Predbat keeps running
# perfectly and simply writes its logs back onto the replicated PVC, which is
# the thing this image exists to prevent. Nothing about that is visible without
# starting the container and looking at where the bytes landed.
#
# So this starts it against a stub Home Assistant, waits for it to come up, and
# then checks the state volume is free of logs - including across a rotation,
# which is where a symlink-based approach silently fails.
#
# Usage: verify.sh <image>
set -euo pipefail

image="${1:?image}"
name="predbat-verify-$$"
net="predbat-verify-net-$$"
ha="predbat-ha-$$"

workdir="$(mktemp -d)"
cleanup() {
    docker rm -f "${name}" "${ha}" >/dev/null 2>&1 || true
    docker network rm "${net}" >/dev/null 2>&1 || true
    rm -rf "${workdir}"
}
trap cleanup EXIT

docker network create "${net}" >/dev/null

# --- a stub Home Assistant -------------------------------------------------
# Predbat refuses to start without one: it fetches the entity list over REST
# before it does anything else. This serves just enough of the API for startup
# to get past that and reach the point where it is logging steadily.
cat >"${workdir}/ha_stub.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/services"):
            # Must be non-empty: ha.py treats a falsy /api/services as "cannot
            # reach Home Assistant" and aborts startup with a bare ValueError.
            self._send([{"domain": "script", "services": {"turn_on": {}}}])
        elif self.path.startswith("/api/states"):
            self._send([])
        elif self.path.startswith("/api/config"):
            self._send({"version": "2026.8.0", "unit_system": {}, "time_zone": "UTC"})
        elif self.path.startswith("/api/"):
            self._send({"message": "API running."})
        else:
            self._send({}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        self._send([])

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 8123), Handler).serve_forever()
PY

docker run -d --name "${ha}" --network "${net}" \
    -v "${workdir}/ha_stub.py:/ha_stub.py:ro" \
    python:3.13-slim-trixie python3 /ha_stub.py >/dev/null

# --- Predbat's own config --------------------------------------------------
# A minimal apps.yaml. ha_url/ha_key are the whole point of running outside the
# add-on: with no Supervisor there is no SUPERVISOR_TOKEN, and Predbat falls
# back to these.
mkdir -p "${workdir}/config" "${workdir}/logs"
cat >"${workdir}/config/apps.yaml" <<CONF
pred_bat:
  module: predbat
  class: PredBat
  prefix: predbat
  timezone: UTC
  ha_url: 'http://${ha}:8123'
  ha_key: 'verify-token'
  threads: 1
  inverter_type: TESLA
  num_inverters: 1
  num_cars: 0
  soc_max:
    - 10.0
  battery_rate_max:
    - 5000
CONF

# The uid the image runs as; the bind mounts are root-owned otherwise and
# Predbat cannot write its state or its logs.
chmod -R 0777 "${workdir}/config" "${workdir}/logs"

echo "::group::start ${image}"
docker run -d --name "${name}" --network "${net}" \
    -v "${workdir}/config:/config" \
    -v "${workdir}/logs:/var/log/predbat" \
    "${image}" >/dev/null
echo "::endgroup::"

# --- wait for it to be logging ---------------------------------------------
echo "==> waiting for Predbat to start"
deadline=$((SECONDS + 120))
while [ $SECONDS -lt $deadline ]; do
    if [ -s "${workdir}/logs/predbat.log" ]; then
        break
    fi
    if ! docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true; then
        echo "ERROR: container exited during startup." >&2
        docker logs "${name}" >&2
        exit 1
    fi
    sleep 2
done

if [ ! -s "${workdir}/logs/predbat.log" ]; then
    echo "ERROR: no predbat.log in \$PREDBAT_LOG_DIR after 120s." >&2
    echo "       Either Predbat never started, or the log redirection broke" >&2
    echo "       and it is logging somewhere else - check /config below." >&2
    ls -la "${workdir}/config" >&2
    docker logs "${name}" >&2
    exit 1
fi
echo "    predbat.log is in the log directory ($(wc -c <"${workdir}/logs/predbat.log") bytes)"

# --- the actual assertion: no logs on the state volume ---------------------
echo "==> checking the state volume is free of logs"
leaked="$(find "${workdir}/config" -name 'predbat*.log' 2>/dev/null || true)"
if [ -n "${leaked}" ]; then
    echo "ERROR: log files landed on the state volume:" >&2
    echo "${leaked}" >&2
    exit 1
fi
echo "    none"

# --- and that it survives a rotation ---------------------------------------
# This is the case a symlink farm passes right up until the first rotation and
# then fails forever: os.rename() renames the symlink, and the reopen creates a
# real file on the PVC. Force the rotation rather than waiting 10MiB for it.
echo "==> forcing a log rotation"
# Rotation is driven by self.logfile.tell() - the offset of Predbat's *own*
# open handle - so appending from outside does not trigger it: the handle's
# offset is unchanged and Predbat never notices. Padding the same file does
# work, because Predbat appends after the padding and its next tell() is then
# past the threshold.
#
# This is the check that matters. A symlink-based redirect passes every
# assertion above and fails only here, on the first rotation, by quietly
# reopening a real predbat.log on the state volume.
docker exec -u 0 "${name}" python3 -c "
import os
path = os.path.join(os.environ['PREDBAT_LOG_DIR'], 'predbat.log')
handle = open(path, 'r+b')
handle.seek(0, os.SEEK_END)
handle.write(b'x' * (10 * 1000 * 1000))
handle.close()
"

# The rotation happens on Predbat's next log() from the main thread. Its
# normal cycle logs continuously, so this arrives without prompting.
echo "==> waiting for the rotation to happen"
deadline=$((SECONDS + 180))
rotated=""
while [ $SECONDS -lt $deadline ]; do
    if [ -f "${workdir}/logs/predbat.1.log" ]; then
        rotated=yes
        break
    fi
    if ! docker inspect -f "{{.State.Running}}" "${name}" 2>/dev/null | grep -q true; then
        echo "ERROR: container exited while waiting for rotation." >&2
        docker logs --tail 40 "${name}" >&2
        exit 1
    fi
    sleep 3
done

if [ -z "${rotated}" ]; then
    echo "ERROR: no rotation after 180s. The rotation path is precisely what" >&2
    echo "       this image patches, so it must not go unverified." >&2
    ls -la "${workdir}/logs" >&2
    ls -la "${workdir}/config" >&2
    docker logs --tail 40 "${name}" >&2
    exit 1
fi
echo "    rotated: predbat.1.log is in the log directory"

leaked="$(find "${workdir}/config" -name "predbat*.log" 2>/dev/null || true)"
if [ -n "${leaked}" ]; then
    echo "ERROR: after rotation, log files landed on the state volume:" >&2
    echo "${leaked}" >&2
    echo "       This is the symlink failure mode - the rotation renamed the" >&2
    echo "       redirect away and Predbat reopened a real file on the PVC." >&2
    exit 1
fi
echo "==> state volume still free of logs after rotation"

# --- state itself must be on the state volume ------------------------------
# The mirror image of the above: redirecting too much would put Predbat's
# config and models in the emptyDir, where they are lost on every restart.
echo "==> checking state is on the state volume"
if [ ! -f "${workdir}/config/predbat_config.json" ]; then
    echo "WARN: predbat_config.json not written yet; it appears once Predbat" >&2
    echo "      completes a cycle. Not failing on it." >&2
else
    echo "    predbat_config.json is on the state volume"
fi

stray="$(find "${workdir}/logs" -name 'predbat_config.json' -o -name '*.npz' 2>/dev/null || true)"
if [ -n "${stray}" ]; then
    echo "ERROR: Predbat state landed in the log directory (lost on restart):" >&2
    echo "${stray}" >&2
    exit 1
fi

# --- no runtime dependency on GitHub ---------------------------------------
# Without a baked manifest.yaml Predbat calls the GitHub contents API on every
# start to rebuild it, and then cannot write it into root-owned /opt/predbat.
# That is an unauthenticated API call on every pod start plus a recurring error
# that reads like a fault, so assert the manifest is doing its job.
echo "==> checking the install self-check needs no network"
if docker logs "${name}" 2>&1 | grep -q "Failed to write manifest"; then
    echo "ERROR: Predbat tried to rebuild manifest.yaml at runtime." >&2
    echo "       The image should ship one - see write-manifest.py." >&2
    docker logs "${name}" 2>&1 | grep -i manifest >&2
    exit 1
fi
if docker logs "${name}" 2>&1 | grep -qi "Manifest file .* is missing"; then
    echo "ERROR: Predbat found no manifest.yaml and fell back to GitHub." >&2
    docker logs "${name}" 2>&1 | grep -i manifest >&2
    exit 1
fi
# A manifest that does not match the image is worse than none: it warns about
# size and SHA mismatches on every start, which trains you to ignore the
# startup output. The patched and pruned files must be described as they are.
if docker logs "${name}" 2>&1 | grep -qE "(size mismatch|SHA mismatch|is missing|is zero bytes)"; then
    echo "ERROR: manifest.yaml does not describe the image's own files:" >&2
    docker logs "${name}" 2>&1 | grep -E "(size mismatch|SHA mismatch|is missing|is zero bytes)" >&2
    exit 1
fi
echo "    manifest.yaml matches the installed files"

# --- it must not be running as root ----------------------------------------
user="$(docker exec "${name}" id -u)"
echo "==> running as uid: ${user}"
if [ "${user}" = "0" ]; then
    echo "ERROR: Predbat is running as root." >&2
    exit 1
fi

echo "==> all checks passed"
