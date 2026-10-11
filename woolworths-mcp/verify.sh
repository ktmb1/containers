#!/usr/bin/env bash
# Verify a built woolworths-mcp image serves MCP over HTTP and can launch its
# browser.
#
# What this image adds to the source shows up only at runtime, on the first
# tool call:
#   - the HTTP transport (MCP_TRANSPORT=http; without it the server would
#     wait on stdio and never listen)
#   - Debian's chromium in place of Puppeteer's download (a wrong
#     PUPPETEER_EXECUTABLE_PATH fails with "Could not find Chrome")
#   - a headless launch under a read-only root with /tmp as the only writable
#     path ("Missing X server", or a profile directory it cannot create)
#
# So this starts the image the way the pod runs it - non-root, read-only root
# filesystem, /tmp as the only writable path - and calls
# woolworths_search_products. There is no setup call any more: the server
# launches Chromium for its cookies on that first call.
#
# Whether woolworths.com.au then answers is not asserted. That depends on the
# runner's network and on Woolworths' bot protection, neither of which this
# image controls. What is asserted is that Chromium launched: the call either
# returns products or fails on navigation or the API, never on launch.
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
        "${url}/mcp" -d "$1"
}

echo "==> initialize"
init="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}')"
if ! grep -q '"woolworths-mcp-server"' <<<"${init}"; then
    echo "ERROR: initialize did not reach the Woolworths server:" >&2
    echo "${init}" >&2
    docker logs "${name}" >&2
    exit 1
fi
# Stateless on purpose: a session id would be one a restarted pod no longer
# knows, and every client holding it would get 404s until it reconnected.
if grep -qi '^mcp-session-id:' "${headers}"; then
    echo "ERROR: the server issued an mcp-session-id - it is meant to be stateless." >&2
    exit 1
fi

echo "==> tools/list"
tools="$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
# The tools home-ops' MCPRoute allow-lists. If a release renames one, the
# gateway would silently stop offering it.
for tool in woolworths_search_products woolworths_get_product_details \
    woolworths_find_healthier woolworths_get_specials woolworths_get_categories; do
    if ! grep -q "\"${tool}\"" <<<"${tools}"; then
        echo "ERROR: ${tool} is missing from tools/list." >&2
        echo "${tools}" >&2
        exit 1
    fi
done
# The cart tools change state and are off unless WOOLWORTHS_ENABLE_CART=true.
if grep -q '"woolworths_add_to_cart"' <<<"${tools}"; then
    echo "ERROR: cart tools are listed; they should be off by default." >&2
    exit 1
fi
echo "    all allow-listed tools present, no cart tools"

echo "==> woolworths_search_products (launches Chromium for cookies)"
result="$(mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"woolworths_search_products","arguments":{"searchTerm":"milk","pageSize":2}}}' 120)"
echo "    ${result}" | head -c 600
echo
for launch_failure in "Missing X server" "Could not find Chrome" "Failed to launch" "No usable sandbox" "EROFS"; do
    if grep -q "${launch_failure}" <<<"${result}"; then
        echo "ERROR: Chromium did not launch (${launch_failure})." >&2
        docker logs "${name}" >&2
        exit 1
    fi
done
if ! grep -q '"content"' <<<"${result}"; then
    echo "ERROR: woolworths_search_products returned no tool result." >&2
    docker logs "${name}" >&2
    exit 1
fi
if grep -q '\\"products\\"' <<<"${result}"; then
    echo "    products returned"
else
    echo "    no products (Woolworths unreachable or refused from this runner) - not asserted"
fi

user="$(docker exec "${name}" id -u)"
if [ "${user}" = "0" ]; then
    echo "ERROR: running as root." >&2
    exit 1
fi

echo "==> all checks passed"
