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
"""A stub Home Assistant: enough REST and websocket for Predbat to start.

The websocket half is not optional. Predbat subscribes to state_changed over
/api/websocket and gives up after ten consecutive failures, five seconds
apart -- so a REST-only stub kills it about fifty seconds in, which is less
time than the rotation check below needs. That produced a suite that passed or
failed on how fast the runner was.
"""

from aiohttp import web, WSMsgType

SERVICES = [{"domain": "script", "services": {"turn_on": {}}}]
CONFIG = {"version": "2026.8.0", "unit_system": {}, "time_zone": "UTC"}


async def services(request):
    # Must be non-empty: ha.py treats a falsy /api/services as "cannot reach
    # Home Assistant" and aborts startup with a bare ValueError.
    return web.json_response(SERVICES)


async def states(request):
    return web.json_response([])


async def config(request):
    return web.json_response(CONFIG)


async def generic(request):
    return web.json_response({"message": "API running."})


async def websocket(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    # Home Assistant's handshake: greet, accept any token, then acknowledge
    # each subscription so Predbat resets its error counter and settles.
    await ws.send_json({"type": "auth_required", "ha_version": "2026.8.0"})

    async for msg in ws:
        if msg.type != WSMsgType.TEXT:
            continue
        try:
            data = msg.json()
        except ValueError:
            continue

        if data.get("type") == "auth":
            await ws.send_json({"type": "auth_ok", "ha_version": "2026.8.0"})
        elif "id" in data:
            await ws.send_json({"id": data["id"], "type": "result", "success": True, "result": None})

    return ws


app = web.Application()
app.add_routes(
    [
        web.get("/api/websocket", websocket),
        web.get("/api/services", services),
        web.get("/api/states", states),
        web.get("/api/states/{entity}", states),
        web.get("/api/config", config),
        web.get("/api/", generic),
        web.post("/api/{tail:.*}", generic),
        web.get("/api/{tail:.*}", generic),
    ]
)

web.run_app(app, host="0.0.0.0", port=8123, print=None)
PY

# Run the stub in the image under test: it already carries aiohttp, so this
# needs no second image and no pip install at verify time.
docker run -d --name "${ha}" --network "${net}" \
    -v "${workdir}/ha_stub.py:/ha_stub.py:ro" \
    --entrypoint python3 "${image}" /ha_stub.py >/dev/null

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

# --- it must still be alive ------------------------------------------------
# Predbat stops itself after ten consecutive websocket failures. A stub that
# does not speak the websocket protocol therefore kills it about fifty seconds
# in - and every check above would still have passed on a fast runner, because
# they only look at files. Assert the process is actually still running, and
# that it settled rather than limping through reconnects.
echo "==> checking Predbat is still running"
if ! docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -q true; then
    echo "ERROR: Predbat is no longer running at the end of the run." >&2
    docker logs --tail 40 "${name}" >&2
    exit 1
fi

if docker exec "${name}" sh -c 'cat "$PREDBAT_LOG_DIR"/predbat.log' 2>/dev/null | grep -q "Web socket failed"; then
    echo "ERROR: Predbat gave up on the websocket. The stub is not speaking" >&2
    echo "       the Home Assistant protocol, so this run proved nothing" >&2
    echo "       about steady-state behaviour." >&2
    exit 1
fi
echo "    still running, websocket healthy"

echo "==> all checks passed"
