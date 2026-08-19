#!/usr/bin/env bash
# Verify a built timescaledb-extension image actually loads in the CNPG operand.
#
# The Dockerfile's own checks confirm the right *files* were produced. They
# cannot confirm those files load: an extension built against the wrong Postgres
# minor compiles and packages perfectly, then fails at dlopen() with something
# like `undefined symbol: palloc0_mul`. That surfaces in the cluster, as
# Postgres refusing to start, which is far too late.
#
# So: mount the extension into the operand exactly as CNPG does, and exercise
# every version the image claims to ship.
#
# Usage: verify.sh <extension-dir> <operand-image> <default-version> <all-versions>
set -euo pipefail

ext_dir="${1:?extension directory}"
operand="${2:?operand image}"
default_version="${3:?default version}"
all_versions="${4:?space-separated versions}"

echo "Verifying against ${operand}"
echo "  default version: ${default_version}"
echo "  all versions:    ${all_versions}"

for v in ${all_versions}; do
    test -f "${ext_dir}/lib/timescaledb-${v}.so" \
        || { echo "missing lib/timescaledb-${v}.so in built image" >&2; exit 1; }
done

# Each version gets its own run: a database records one version in pg_extension,
# and the loader dlopen()s exactly that .so. Testing them in one database would
# only ever exercise the last one installed.
for v in ${all_versions}; do
    echo "::group::verify TimescaleDB ${v} in ${operand}"
    docker run --rm \
        -e TS_VERSION="${v}" \
        -e TS_DEFAULT="${default_version}" \
        -v "${ext_dir}/lib:/ext/lib:ro" \
        -v "${ext_dir}/share/extension:/ext/share/extension:ro" \
        --entrypoint bash \
        "${operand}" -euo pipefail -c '
            export PGDATA=/tmp/pgdata
            initdb -D "$PGDATA" -U postgres >/dev/null
            cat >> "$PGDATA/postgresql.conf" <<CONF
dynamic_library_path = '"'"'\$libdir:/ext/lib'"'"'
extension_control_path = '"'"'\$system:/ext/share'"'"'
shared_preload_libraries = '"'"'timescaledb'"'"'
max_worker_processes = 16
unix_socket_directories = '"'"'/tmp'"'"'
CONF
            if ! pg_ctl -D "$PGDATA" -w -l /tmp/pg.log start >/dev/null; then
                echo "postgres failed to start with timescaledb preloaded:" >&2
                cat /tmp/pg.log >&2
                exit 1
            fi
            q() { psql -h /tmp -U postgres -tAX -c "$1"; }

            # Install the exact version under test, not the default.
            q "CREATE EXTENSION timescaledb VERSION '"'"'${TS_VERSION}'"'"';" >/dev/null
            got="$(q "SELECT extversion FROM pg_extension WHERE extname='"'"'timescaledb'"'"';")"
            [ "$got" = "${TS_VERSION}" ] \
                || { echo "expected ${TS_VERSION} in catalog, got ${got}" >&2; exit 1; }

            # A bare query proves the loader can dlopen the catalog version:
            # this is what fails for every session when a .so is missing.
            q "SELECT 1;" >/dev/null

            # And the extension has to actually work, not just load.
            q "CREATE TABLE m(t timestamptz NOT NULL, v float8);" >/dev/null
            q "SELECT create_hypertable('"'"'m'"'"','"'"'t'"'"');" >/dev/null
            q "INSERT INTO m SELECT now()-(g||'"'"' min'"'"')::interval, random()
               FROM generate_series(1,1000) g;" >/dev/null
            rows="$(q "SELECT count(*) FROM m;")"
            [ "$rows" = "1000" ] || { echo "expected 1000 rows, got $rows" >&2; exit 1; }
            chunks="$(q "SELECT count(*) FROM timescaledb_information.chunks
                         WHERE hypertable_name='"'"'m'"'"';")"
            [ "$chunks" -ge 1 ] || { echo "hypertable produced no chunks" >&2; exit 1; }

            # A legacy version must be upgradable to the default - that is the
            # only reason it is still in the image.
            if [ "${TS_VERSION}" != "${TS_DEFAULT}" ]; then
                q "ALTER EXTENSION timescaledb UPDATE;" >/dev/null
                after="$(q "SELECT extversion FROM pg_extension WHERE extname='"'"'timescaledb'"'"';")"
                [ "$after" = "${TS_DEFAULT}" ] \
                    || { echo "update from ${TS_VERSION} landed on ${after}, want ${TS_DEFAULT}" >&2; exit 1; }
                still="$(q "SELECT count(*) FROM m;")"
                [ "$still" = "1000" ] \
                    || { echo "rows lost across update: $still" >&2; exit 1; }
                echo "  ${TS_VERSION} loads, works, and updates to ${TS_DEFAULT}"
            else
                echo "  ${TS_VERSION} loads and works"
            fi
        '
    echo "::endgroup::"
done

echo "All ${all_versions} verified against ${operand}."
