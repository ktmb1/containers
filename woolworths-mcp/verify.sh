#!/usr/bin/env bash
# Verify a built woolworths-mcp image serves MCP over HTTP and can launch its
# browser.
#
# Nothing this image adds to upstream shows up in a build. Each part fails only
# at runtime, and only on the first tool call:
#   - supergateway in front of the stdio server (a wrong --stdio command still
#     serves /healthz happily)
#   - --stateful (without it every request gets a fresh child, and the cookies
#     woolworths_get_cookies captured are gone by the next call)
#   - the forced-headless patch (unpatched, woolworths_open_browser with no
#     arguments dies with "Missing X server")
#   - Debian's chromium in place of Puppeteer's download (a wrong
#     PUPPETEER_EXECUTABLE_PATH fails with "Could not find Chrome")
#
# So this starts the image the way the pod runs it - non-root, read-only root
# filesystem, /tmp as the only writable path - opens an MCP session, and calls
# woolworths_open_browser asking for a VISIBLE browser.
#
# Whether woolworths.com.au then loads is not asserted. That depends on the
# runner's network and on Woolworths' bot protection, neither of which this
# image controls. What is asserted is that Chromium launched: the call either
# succeeds or fails on navigation, never on launch.
#
# Usage: verify.sh <image>
set -euo pipefail

image="${1:?image}"
name="woolworths-mcp-verify-$$"
port=18000

cleanup() {
    docker rm -f "${name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "::group::start ${image}"
docker run -d --name "${name}" \
    --user 1000:1000 \
    --read-only \
    --tmpfs /tmp:uid=1000,gid=1000 \
    --shm-size 512m \
    -p "127.0.0.1:${port}:8000" \
    "${image}" >/dev/null
echo "::endgroup::"

url="http://127.0.0.1:${port}"

echo "==> waiting for /healthz"
deadline=$((SECONDS + 60))
until curl -fsS "${url}/healthz" >/dev/null 2>&1; do
    if [ $SECONDS -ge $deadline ]; then
        echo "ERROR: /healthz did not answer within 60s." >&2
        docker logs "${name}" >&2
        exit 1
    fi
    sleep 1
done

headers="$(mktemp)"
mcp() {
    curl -fsS -m "${2:-30}" -D "${headers}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${session:+-H "mcp-session-id: ${session}"} \
        "${url}/mcp" -d "$1"
}

echo "==> initialize"
session=""
init="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}')"
if ! grep -q '"woolworths-mcp-server"' <<<"${init}"; then
    echo "ERROR: initialize did not reach the Woolworths server:" >&2
    echo "${init}" >&2
    docker logs "${name}" >&2
    exit 1
fi
# Stateful mode hands out a session id; stateless does not. Its absence means
# --stateful is gone and the cookie flow cannot work.
session="$(grep -i '^mcp-session-id:' "${headers}" | awk '{print $2}' | tr -d '\r')"
if [ -z "${session}" ]; then
    echo "ERROR: no mcp-session-id header - supergateway is not in stateful mode." >&2
    exit 1
fi
echo "    session ${session}"
mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true

echo "==> tools/list"
tools="$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
# The tools home-ops' MCPRoute allow-lists. If upstream renames one, the
# gateway would silently stop offering it.
for tool in woolworths_open_browser woolworths_get_cookies woolworths_close_browser \
    woolworths_search_products woolworths_get_product_details \
    woolworths_get_specials woolworths_get_categories; do
    if ! grep -q "\"${tool}\"" <<<"${tools}"; then
        echo "ERROR: ${tool} is missing from tools/list." >&2
        echo "${tools}" >&2
        exit 1
    fi
done
echo "    all allow-listed tools present"

echo "==> woolworths_open_browser (asking for headless: false)"
result="$(mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"woolworths_open_browser","arguments":{"headless":false}}}' 120)"
echo "    ${result}" | head -c 600
echo
for launch_failure in "Missing X server" "Could not find Chrome" "Failed to launch" "No usable sandbox"; do
    if grep -q "${launch_failure}" <<<"${result}"; then
        echo "ERROR: Chromium did not launch (${launch_failure})." >&2
        docker logs "${name}" >&2
        exit 1
    fi
done
if ! grep -qE '\\"success\\": (true|false)' <<<"${result}"; then
    echo "ERROR: woolworths_open_browser returned no tool result." >&2
    docker logs "${name}" >&2
    exit 1
fi
if ! docker exec "${name}" sh -c 'ls /proc/*/cmdline | xargs -r cat 2>/dev/null | tr "\0" " "' | grep -q -- "--headless"; then
    echo "ERROR: no headless Chromium process in the container." >&2
    exit 1
fi
echo "    Chromium launched headless"

user="$(docker exec "${name}" id -u)"
if [ "${user}" = "0" ]; then
    echo "ERROR: running as root." >&2
    exit 1
fi

echo "==> all checks passed"
