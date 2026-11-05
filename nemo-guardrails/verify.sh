#!/usr/bin/env bash
# Verify a built nemo-guardrails image masks everything it forwards.
#
# A build proves nothing here. The masking leans on a NeMo internal (see
# rails/scrub/actions.py) and on a workaround for a 0.24.1 bug, and every way
# either can break produces a proxy that starts, answers 200 and forwards
# personal data - or, for the bug, answers 200 with an empty reply and never
# calls the model at all. So this runs the image the way the pod does and
# reads what a fake upstream actually received.
#
# Everything runs on an --internal network with no route out, which also
# proves the image downloads nothing at runtime (a spaCy model, a fastembed
# embedding) - the cluster's NetworkPolicy would block that too, and it would
# show up there as a hang on the first request.
#
# Usage: verify.sh <image>
set -euo pipefail

image="${1:?image}"
here="$(cd "$(dirname "$0")" && pwd)"
id="nemo-verify-$$"
net="${id}"
work="$(mktemp -d)"

cleanup() {
    docker rm -f "${id}-upstream" "${id}-proxy" "${id}-nonames" >/dev/null 2>&1 || true
    docker network rm "${net}" >/dev/null 2>&1 || true
    rm -rf "${work}"
}
trap cleanup EXIT

# The container user (65532) has to write the upstream log here.
chmod 0777 "${work}"
# Fake names, matching verify/check.py.
printf '# fake household\nZebedee\nQuillon\n' >"${work}/names.txt"
chmod 0644 "${work}/names.txt"

run_as_pod=(--user 65532:65532 --read-only --tmpfs /tmp:mode=1777 --cap-drop ALL --security-opt no-new-privileges)

echo "==> a names file that is configured but missing must stop the start"
# Detached and polled, not run in the foreground: if the check regressed, the
# server would start and this step would hang instead of failing.
docker run -d --name "${id}-nonames" "${run_as_pod[@]}" --network none \
    -e SCRUBBER_NAMES_FILE=/does/not/exist \
    -e MAIN_MODEL_BASE_URL=http://unused/v1 -e OPENAI_API_KEY=unused \
    "${image}" >/dev/null
deadline=$((SECONDS + 120))
while [ "$(docker inspect -f '{{.State.Running}}' "${id}-nonames")" = "true" ]; do
    if [ $SECONDS -ge $deadline ]; then
        echo "ERROR: the proxy kept running without its names file." >&2
        docker logs "${id}-nonames" >&2
        exit 1
    fi
    sleep 2
done
# And for the right reason - a container that fails to start at all (a bad
# run option, a missing module) would pass the check above too.
if ! docker logs "${id}-nonames" 2>&1 | grep -q "No such file or directory: '/does/not/exist'"; then
    echo "ERROR: the proxy exited, but not because of the missing names file:" >&2
    docker logs "${id}-nonames" >&2
    exit 1
fi
echo "    refused, as it should"

docker network create --internal "${net}" >/dev/null

echo "::group::start the fake upstream and the proxy"
docker run -d --name "${id}-upstream" --network "${net}" --network-alias upstream \
    "${run_as_pod[@]}" \
    -v "${here}/verify:/verify:ro" -v "${work}:/work" \
    --entrypoint python3 "${image}" /verify/upstream.py /work/upstream.jsonl >/dev/null

docker run -d --name "${id}-proxy" --network "${net}" --network-alias proxy \
    "${run_as_pod[@]}" \
    -v "${work}/names.txt:/names/names.txt:ro" \
    -e SCRUBBER_NAMES_FILE=/names/names.txt \
    -e MAIN_MODEL_BASE_URL=http://upstream:8080/v1 \
    -e OPENAI_API_KEY=verify-upstream-key \
    "${image}" >/dev/null
echo "::endgroup::"

# Probes from a throwaway container on the same network: an --internal network
# cannot publish ports to the host.
on_net() {
    docker run --rm --network "${net}" "${run_as_pod[@]}" \
        -v "${here}/verify:/verify:ro" -v "${work}:/work" \
        --entrypoint python3 "${image}" "$@"
}

echo "==> waiting for /healthz"
if ! on_net -c '
import time, urllib.request
deadline = time.time() + 180
while time.time() < deadline:
    try:
        urllib.request.urlopen("http://proxy:8000/healthz", timeout=5)
        raise SystemExit(0)
    except Exception:
        time.sleep(2)
raise SystemExit(1)
'; then
    echo "ERROR: the proxy did not become healthy within 180s." >&2
    docker logs "${id}-proxy" >&2
    exit 1
fi
docker logs "${id}-proxy" 2>&1 | grep -E 'self-check' || true

if ! on_net /verify/check.py http://proxy:8000 /work/upstream.jsonl; then
    echo "::group::proxy logs"
    docker logs "${id}-proxy" >&2 || true
    echo "::endgroup::"
    exit 1
fi

# Everything passed, but did anything try to leave? A library falling back
# after a failed download still answers correctly here, and in the cluster
# the same attempt is a DNS timeout on some request. Fail on the attempt.
if docker logs "${id}-proxy" 2>&1 | grep -E "NameResolutionError|Failed to resolve|Temporary failure in name resolution|Max retries exceeded"; then
    echo "ERROR: the proxy tried to reach the network at runtime (above)." >&2
    exit 1
fi

user="$(docker exec "${id}-proxy" id -u)"
if [ "${user}" = "0" ]; then
    echo "ERROR: running as root." >&2
    exit 1
fi

echo "==> all checks passed"
