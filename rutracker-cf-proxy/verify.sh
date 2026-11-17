#!/usr/bin/env bash
# Verify a built rutracker-cf-proxy image: the definition it installs carries
# the keyword cap and still parses, the cap cuts where it should, the proxy
# version is the one the tag claims, and the proxy still starts.
#
# The patch is a text edit inside an installed package, so a build proves only
# that the script ran. What matters is what `install-definition` writes into
# Prowlarr - so run it the way home-ops does (non-root, read-only root, into an
# empty directory) and read the result.
#
# The cut is checked with Python's re, not Prowlarr's .NET engine. The pattern
# uses nothing the two treat differently (a bounded `.`, a lookahead on \s or
# end, `$1`), and the inputs are already past upstream's punctuation filter,
# whose \p{L} Python's re cannot express.
#
# Usage: verify.sh <image> <expected upstream version>
set -euo pipefail

image="${1:?image}"
version="${2:?expected version}"
name="rutracker-cf-proxy-verify-$$"
out="$(mktemp -d)"
chmod 0777 "${out}"

cleanup() {
    docker rm -f "${name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "::group::upstream version"
got="$(docker run --rm --entrypoint pip "${image}" show rutracker-proxy | sed -n 's/^Version: //p')"
echo "image has ${got}, matrix says ${version}"
[ "${got}" = "${version}" ] || { echo "version mismatch: bump the FROM and the matrix together"; exit 1; }
echo "::endgroup::"

echo "::group::install-definition"
docker run --rm --user 1000:1000 --read-only \
    -v "${out}:/definitions" \
    -e PUBLIC_URL=http://rutracker-proxy.media.svc.cluster.local:8080/ \
    "${image}" install-definition
def="${out}/rutracker-proxy.yml"
test -s "${def}"
echo "::endgroup::"

echo "::group::definition"
# Parses as YAML at all.
yq -e '.id == "rutracker-proxy"' "${def}" >/dev/null
# The cap is the second-to-last keywords filter, followed by a trim, and
# upstream's two filters are still ahead of it.
filters="$(yq -o=json -I=0 '.search.keywordsfilters' "${def}")"
echo "${filters}"
pattern="$(yq '.search.keywordsfilters[-2].args[0]' "${def}")"
[ "$(yq '.search.keywordsfilters[-2].name' "${def}")" = "re_replace" ]
[ "${pattern}" = '^(.{1,90})(?=\s|$).*$' ]
[ "$(yq '.search.keywordsfilters[-2].args[1]' "${def}")" = '$1' ]
[ "$(yq '.search.keywordsfilters[-1].name' "${def}")" = "trim" ]
[ "$(yq '.search.keywordsfilters | length' "${def}")" -ge 5 ]
# links still points where home-ops asked.
yq -e '.links[0] == "http://rutracker-proxy.media.svc.cluster.local:8080/"' "${def}" >/dev/null
echo "::endgroup::"

echo "::group::cut"
python3 - "${pattern}" <<'EOF'
import re, sys

pattern = sys.argv[1]

def cut(s):
    # Cardigann's re_replace is .NET Regex.Replace; "$1" there is \g<1> here.
    return re.sub(pattern, r"\g<1>", s).strip()

cases = [
    # Shelfarr's real query for the book that found nothing (punctuation
    # already stripped by upstream's filter). Cut lands after "радостям":
    # the 88-character query that found it.
    (
        "Откуда берутся дети Краткий путеводитель по переходу из лагеря чайлдфри "
        "к тихим радостям семейственности Ася Казанцева",
        "Откуда берутся дети Краткий путеводитель по переходу из лагеря чайлдфри "
        "к тихим радостям",
    ),
    # Short queries are untouched.
    ("Акунин Борис", "Акунин Борис"),
    ("Казанцева Откуда берутся дети", "Казанцева Откуда берутся дети"),
    # Exactly 90 is kept whole.
    ("а" * 44 + " " + "б" * 45, "а" * 44 + " " + "б" * 45),
    # 91 drops the word that crosses the line, never half of it.
    ("а" * 44 + " " + "б" * 46, "а" * 44),
    # One word longer than the cap cannot be cut on a boundary: unchanged.
    ("я" * 120, "я" * 120),
]
failed = False
for query, want in cases:
    got = cut(query)
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {len(query):3} -> {len(got):3}  {got[:60]}")
    failed |= not ok
sys.exit(1 if failed else 0)
EOF
echo "::endgroup::"

echo "::group::proxy starts"
docker run -d --name "${name}" --user 1000:1000 --read-only \
    --tmpfs /data:mode=1777 --tmpfs /tmp:mode=1777 \
    -e BYPARR_URL=http://127.0.0.1:1/v1 \
    -p 18080:8080 "${image}" >/dev/null
for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:18080/health >/dev/null 2>&1; then
        echo "/health answered"
        echo "::endgroup::"
        exit 0
    fi
    sleep 1
done
docker logs "${name}"
echo "proxy did not answer /health within 30s"
exit 1
