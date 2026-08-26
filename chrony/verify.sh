#!/usr/bin/env bash
# Verify a built chrony image actually serves NTP.
#
# A chrony image that builds tells you nothing: every failure this image hit
# during development produced a perfectly good image that died at runtime.
#
#   - a USER directive        -> "Fatal error : Not superuser"
#   - no /run/chrony          -> "Could not open /run/chrony/chronyd.pid"
#   - too few capabilities    -> "cap_set_proc() failed"
#
# and one that did not even die: with a `local` directive in chrony.conf,
# chronyd runs happily and serves stratum 10 from its own reference while
# tracking upstream at microsecond accuracy - so LAN clients get a source that
# looks far worse than it is. None of that is visible without starting the
# container and asking it the time, so that is what this does.
#
# Usage: verify.sh <image> [host-port]
set -euo pipefail

image="${1:?image}"
port="${2:-12123}"
name="chrony-verify-$$"

cleanup() { docker rm -f "${name}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

workdir="$(mktemp -d)"
cat >"${workdir}/chrony.conf" <<'CONF'
server 162.159.200.1 iburst
server 162.159.200.123 iburst
driftfile /var/lib/chrony/chrony.drift
# Wider than any real deployment's allow list on purpose: the probe below
# arrives over Docker's published port, so its source is the bridge gateway
# rather than 127.0.0.1, and that address differs by Docker backend
# (172.17.0.1 on Linux CI, 192.168.127.1 under Docker Desktop). A narrow list
# here silently drops the probe and reads as a timeout.
allow all
ratelimit interval 3 burst 8
CONF

echo "::group::start ${image}"
# Capabilities mirror the consuming pod's securityContext exactly. If this list
# and the manifest drift apart, this stops testing what actually runs - notably
# NET_BIND_SERVICE and SETPCAP, without which chronyd aborts at startup.
docker run -d --name "${name}" \
    --cap-drop ALL \
    --cap-add NET_BIND_SERVICE --cap-add SETPCAP \
    --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
    -v "${workdir}/chrony.conf:/etc/chrony/chrony.conf:ro" \
    -p "${port}:123/udp" \
    "${image}" >/dev/null
echo "::endgroup::"

# `chronyc tracking` exits 0 even while unsynchronised (stratum 0, "Leap
# status : Not synchronised"), so waiting on its exit code races ahead of the
# first real measurement. waitsync is built for this; the trailing 10 requires
# a stratum below 10, so a local reference does not count as synchronised.
if ! docker exec "${name}" chronyc -n waitsync 60 0 0 10 >/dev/null 2>&1; then
    echo "ERROR: chronyd never synchronised to an upstream source." >&2
    docker logs "${name}" >&2
    exit 1
fi

docker exec "${name}" chronyc -n tracking

stratum="$(docker exec "${name}" chronyc -n tracking | awk '/^Stratum/ {print $3}')"
echo "==> served stratum: ${stratum}"
if [ -z "${stratum}" ] || [ "${stratum}" -ge 10 ]; then
    echo "ERROR: expected a real upstream stratum (<10), got '${stratum}'." >&2
    echo "       chronyd is serving its own reference - check that no 'local'" >&2
    echo "       directive crept into chrony.conf." >&2
    docker logs "${name}" >&2
    exit 1
fi

# The entrypoint's -u must actually take effect; running as root would mean the
# privilege drop silently stopped working.
user="$(docker exec "${name}" ps -o user= -C chronyd | head -1 | tr -d ' ')"
echo "==> chronyd running as: ${user}"
if [ "${user}" = "root" ]; then
    echo "ERROR: chronyd is still running as root after startup." >&2
    exit 1
fi

echo "==> querying it as a real NTP client"
python3 - "${port}" <<'PY'
import socket, sys, time

port = int(sys.argv[1])

# Retry rather than one-shot: a published UDP port can take a moment to start
# forwarding, and losing a single datagram on a connectionless protocol is not
# a reason to fail a build.
data = None
deadline = time.time() + 30
while time.time() < deadline:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    try:
        s.sendto(b"\x1b" + 47 * b"\0", ("127.0.0.1", port))
        data, _ = s.recvfrom(1024)
        break
    except (socket.timeout, TimeoutError, OSError):
        time.sleep(2)
    finally:
        s.close()

if data is None:
    raise SystemExit("ERROR: no NTP reply after 30s")
if len(data) < 48:
    raise SystemExit("ERROR: short NTP reply (%d bytes)" % len(data))

mode, stratum = data[0] & 0x7, data[1]
refid = ".".join(str(b) for b in data[12:16])
print("    mode=%d stratum=%d refid=%s" % (mode, stratum, refid))
if mode != 4:
    raise SystemExit("ERROR: expected mode 4 (server), got %d" % mode)
if stratum == 0 or stratum >= 10:
    raise SystemExit("ERROR: bad stratum in reply: %d" % stratum)
print("    OK: image serves usable NTP")
PY

echo "==> all checks passed"
