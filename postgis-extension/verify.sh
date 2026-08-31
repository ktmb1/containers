#!/usr/bin/env bash
# Verify a built postgis-extension image actually loads in the CNPG operand.
#
# File presence proves very little here. This image bundles shared libraries the
# operand does not have, so the ways it can be broken are all runtime ones: a
# NEEDED library missing from lib/, a control file that is a dangling symlink
# into /etc/alternatives, or PROJ without its proj.db - each of which builds
# perfectly and then fails at CREATE EXTENSION or on the first coordinate
# operation.
#
# So: mount it the way CNPG does, with the same LD_LIBRARY_PATH and PROJ_DATA
# the Cluster sets, and exercise exactly what LTSS does with it.
#
# Usage: verify.sh <extension-dir> <operand-image> <postgis-version>
set -euo pipefail

ext_dir="${1:?extension directory}"
operand="${2:?operand image}"
version="${3:?postgis version}"

echo "Verifying against ${operand}"
echo "  postgis version: ${version}"

test -f "${ext_dir}/lib/postgis-3.so" \
    || { echo "missing lib/postgis-3.so in built image" >&2; exit 1; }
test -f "${ext_dir}/proj/proj.db" \
    || { echo "missing proj/proj.db - PROJ cannot transform without it" >&2; exit 1; }

echo "::group::verify PostGIS ${version} in ${operand}"
docker run --rm \
    -e PG_VERSION="${version}" \
    -v "${ext_dir}/lib:/ext/lib:ro" \
    -v "${ext_dir}/share:/ext/share:ro" \
    -v "${ext_dir}/proj:/ext/proj:ro" \
    --entrypoint bash \
    "${operand}" -euo pipefail -c '
        export PGDATA=/tmp/pgdata
        initdb -D "$PGDATA" -U postgres >/dev/null
        cat >> "$PGDATA/postgresql.conf" <<CONF
dynamic_library_path = '"'"'\$libdir:/ext/lib'"'"'
extension_control_path = '"'"'\$system:/ext/share'"'"'
unix_socket_directories = '"'"'/tmp'"'"'
CONF
        # These two are what the Cluster supplies through
        # spec.postgresql.extensions[].ld_library_path and .env. Without them
        # the extension is present and unusable, so the test must set them the
        # same way rather than papering over it.
        export LD_LIBRARY_PATH=/ext/lib
        export PROJ_DATA=/ext/proj

        if ! pg_ctl -D "$PGDATA" -w -l /tmp/pg.log start >/dev/null; then
            echo "postgres failed to start:" >&2; cat /tmp/pg.log >&2; exit 1
        fi
        q() { psql -h /tmp -U postgres -tAX -v ON_ERROR_STOP=1 -c "$1"; }

        q "CREATE EXTENSION postgis;" >/dev/null
        got="$(q "SELECT extversion FROM pg_extension WHERE extname = '"'"'postgis'"'"';")"
        [ "$got" = "${PG_VERSION}" ] \
            || { echo "expected postgis ${PG_VERSION}, got ${got}" >&2; exit 1; }

        # GEOS and PROJ have to be the bundled ones, actually linked in. If
        # either is missing the extension still installs and then fails on the
        # first real call, so assert the reported build.
        full="$(q "SELECT postgis_full_version();")"
        case "$full" in
            *GEOS=*) ;;
            *) echo "postgis built without GEOS: $full" >&2; exit 1 ;;
        esac
        case "$full" in
            *PROJ=*) ;;
            *) echo "postgis built without PROJ: $full" >&2; exit 1 ;;
        esac

        # Exactly the shape LTSS uses: a geometry(Point,4326) column, written
        # as EWKT, read back as text, with a GiST index over it.
        q "CREATE TABLE t(id int, location geometry(Point,4326));" >/dev/null
        q "INSERT INTO t VALUES (1, '"'"'SRID=4326;POINT(151.2093 -33.8688)'"'"');" >/dev/null
        wkt="$(q "SELECT ST_AsText(location) FROM t;")"
        [ "$wkt" = "POINT(151.2093 -33.8688)" ] \
            || { echo "geometry round trip returned ${wkt}" >&2; exit 1; }
        q "CREATE INDEX ON t USING gist(location);" >/dev/null

        # A real coordinate operation, which is what needs proj.db. Sydney to
        # Melbourne is ~713km; allow a little slack rather than pinning a
        # figure that a PROJ update could legitimately shift by a metre.
        km="$(q "SELECT round(ST_DistanceSphere(
                     location, ST_SetSRID(ST_MakePoint(144.96,-37.81),4326)
                 )::numeric/1000) FROM t;")"
        [ "$km" -ge 700 ] && [ "$km" -le 730 ] \
            || { echo "ST_DistanceSphere returned ${km}km, expected ~713" >&2; exit 1; }

        # spatial_ref_sys has to be populated: LTSS declares SRID 4326.
        n="$(q "SELECT count(*) FROM spatial_ref_sys WHERE srid = 4326;")"
        [ "$n" = "1" ] || { echo "SRID 4326 missing from spatial_ref_sys" >&2; exit 1; }

        echo "  postgis ${PG_VERSION} loads, indexes and projects"
    '
echo "::endgroup::"

echo "PostGIS ${version} verified against ${operand}."
