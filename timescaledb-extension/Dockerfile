# TimescaleDB as a CloudNativePG *extension image volume*, not a full Postgres
# image.
#
# CloudNativePG 1.30 can mount extensions into the operand from OCI images at
# runtime (Cluster spec.postgresql.extensions), so a database can stay on the
# official ghcr.io/cloudnative-pg/postgresql operand instead of running a
# third-party Postgres build just to get one extension.
#
# Nobody publishes TimescaleDB in that form: CNPG ships pgvector and pgaudit
# only, and Timescale ships whole Postgres images. So we build it.
#
# The extension is compiled against the *operand* image, not Docker Hub's
# postgres. This matters more than it looks: a TimescaleDB .so links against
# Postgres server internals, and those change between minor releases. Docker
# Hub's `postgres:18-trixie` is a floating tag that runs ahead of the operand -
# at the time of writing it is 18.6 while the operand is 18.3 - and an extension
# built there fails to load with `undefined symbol: palloc0_mul`, because that
# symbol does not exist in 18.3. The build is green, the image is unusable, and
# nothing catches it until Postgres refuses to start in the cluster.
#
# So build FROM the operand itself, and keep this pinned to the same tag the
# cluster's Cluster.spec.imageName uses.
ARG PG_OPERAND_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie

# The layout is dictated by CNPG and mirrors ghcr.io/cloudnative-pg/pgvector -
# a scratch image with lib/ and share/extension/ at the root. CNPG appends
# those to the operand's dynamic_library_path and extension_control_path.
#
# The image CAN ship more than one TimescaleDB version, and sometimes must.
# TimescaleDB's loader reads the version recorded in the database's pg_extension
# catalog and dlopen()s exactly that timescaledb-<version>.so. If a database is
# on 2.25.2 and the image carries only 2.29.2, *every* session fails with
# `could not access file "timescaledb-2.25.2"` - including a bare SELECT 1,
# because the loader runs before any query. The third-party Postgres image this
# replaced happened to carry nine versions, so the mismatch only surfaced when
# an instance moved to the official operand.
#
# So when raising TIMESCALEDB_VERSION, keep the version the databases are
# actually on in TIMESCALEDB_VERSIONS until they have been moved with
# ALTER EXTENSION timescaledb UPDATE. Only drop a version once no database
# still records it - check with
#   SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
# in every database, on every cluster that mounts this image. The list is
# down to a single version because that check came back clean for 2.25.2.
ARG PG_MAJOR=18

# The version whose control file wins: what CREATE EXTENSION timescaledb
# installs by default, and what ALTER EXTENSION ... UPDATE targets.
ARG TIMESCALEDB_VERSION=2.29.2

# Every version whose .so is built into the image, space separated. Must contain
# TIMESCALEDB_VERSION. Any additional entry is a legacy version kept solely so
# databases still on it can load, and therefore be upgraded.
ARG TIMESCALEDB_VERSIONS="2.29.2"

FROM ${PG_OPERAND_IMAGE} AS build
ARG PG_MAJOR
ARG TIMESCALEDB_VERSION
ARG TIMESCALEDB_VERSIONS

# The operand runs as an unprivileged uid; apt needs root.
USER 0

# postgresql-server-dev-${PG_MAJOR} floats to the newest minor in the pgdg
# archive (18.6) even on an 18.3 image, which would reintroduce exactly the
# header/runtime mismatch this base image was chosen to avoid. Pin the dev
# package to the operand's own postgresql-${PG_MAJOR} version so the headers
# always match the server the extension will be loaded into.
#
# libicu-dev is needed only by the TSL sources: tsl/src/nodes/vector_agg
# includes Postgres' pg_locale.h, which includes <unicode/ucol.h>. The operand
# ships libicu76 at runtime but no headers, so an APACHE_ONLY build never
# needed this and a TSL build fails at 94% without it:
#   fatal error: unicode/ucol.h: No such file or directory
RUN set -eux; \
    apt-get update; \
    pgver="$(dpkg-query -W -f='${Version}' "postgresql-${PG_MAJOR}")"; \
    echo "building against postgresql-${PG_MAJOR} ${pgver}"; \
    apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        libssl-dev libkrb5-dev libicu-dev \
        "postgresql-server-dev-${PG_MAJOR}=${pgver}"; \
    rm -rf /var/lib/apt/lists/*

# Build each requested version in turn, all into the same prefix. The .so files
# are version-suffixed so they accumulate rather than collide, but the shared
# unsuffixed files (the timescaledb.so loader, timescaledb.control) are
# overwritten by each pass. TIMESCALEDB_VERSION is therefore built LAST, so its
# control file - and thus default_version - is the one that survives.
#
# The build deliberately does NOT pass -DAPACHE_ONLY=ON. That flag builds only
# the Apache-2.0 core and omits the TSL module, and it used to be set here with
# a comment claiming the result "still covers hypertables, compression and
# continuous aggregates". Only hypertables was true. Compression and continuous
# aggregates live in tsl/, so an APACHE_ONLY image ships no
# timescaledb-tsl-<version>.so, and the SQL still declares compress_chunk,
# add_compression_policy and add_continuous_aggregate_policy - they just fail
# at CALL time with `functionality not supported under the current license`.
# Nothing catches that at install time, and the old verify.sh did not call them.
#
# Licensing, since this is the reason the flag was there. TSL source is
# available and self-hosting it costs nothing (TSL 2.1: "may be used under this
# TSL Agreement without charge"). What TSL 2.2 prohibits is providing
# database-as-a-service and "copying or distributing any TSL Licensed Software"
# - so the constraint is on PUBLISHING these binaries, not on running them.
#
# Therefore: ghcr.io/ktmb1/timescaledb-extension MUST be a private package.
# It was public when this changed, which was fine for an Apache-only image and
# is not fine for this one. Making it private is a GitHub package setting, not
# something this repo can assert - see the README section this commit adds.
#
# Each pass starts with `cd /`: from the second iteration onward the shell is
# still inside /src/build from the previous one, and `rm -rf /src` would delete
# its own working directory, making the next git clone fail with "Unable to
# read current working directory".
RUN set -eux; \
    case " ${TIMESCALEDB_VERSIONS} " in \
        *" ${TIMESCALEDB_VERSION} "*) ;; \
        *) echo "TIMESCALEDB_VERSIONS must contain TIMESCALEDB_VERSION (${TIMESCALEDB_VERSION})" >&2; \
           exit 1 ;; \
    esac; \
    others=""; \
    for v in ${TIMESCALEDB_VERSIONS}; do \
        [ "$v" = "${TIMESCALEDB_VERSION}" ] || others="${others} $v"; \
    done; \
    for v in ${others} ${TIMESCALEDB_VERSION}; do \
        echo "=== building TimescaleDB $v ==="; \
        cd /; \
        rm -rf /src; \
        git clone --depth 1 --branch "$v" \
            https://github.com/timescale/timescaledb.git /src; \
        cd /src; \
        ./bootstrap -DCMAKE_BUILD_TYPE=RelWithDebInfo -DAPACHE_ONLY=OFF \
            -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF; \
        cd build && make -j"$(nproc)" && make install; \
    done; \
    rm -rf /src

# Collect just the pieces CNPG needs, in the layout it expects.
RUN set -eux; \
    mkdir -p /out/lib /out/share/extension; \
    cp -a "$(pg_config --pkglibdir)"/timescaledb*.so /out/lib/; \
    cp -a "$(pg_config --sharedir)"/extension/timescaledb*.control /out/share/extension/; \
    cp -a "$(pg_config --sharedir)"/extension/timescaledb*.sql /out/share/extension/; \
    ls -la /out/lib /out/share/extension

# Fail the build rather than publish an image that would break a running
# database: every requested version must have produced its own .so and its
# matching TSL .so, and the surviving control file must name
# TIMESCALEDB_VERSION as default_version.
#
# The timescaledb-tsl-$v.so check is what would have caught the APACHE_ONLY
# mistake at build time. Compression and continuous aggregates live in that
# module; without it the image installs cleanly and only fails when a policy is
# actually added, which is far too late. The `cp` glob above already collects
# it - the point of asserting is that a future flag change cannot drop it
# silently.
RUN set -eux; \
    for v in ${TIMESCALEDB_VERSIONS}; do \
        test -f "/out/lib/timescaledb-$v.so" \
            || { echo "missing /out/lib/timescaledb-$v.so" >&2; exit 1; }; \
        test -f "/out/lib/timescaledb-tsl-$v.so" \
            || { echo "missing /out/lib/timescaledb-tsl-$v.so - built without TSL?" >&2; \
                 exit 1; }; \
    done; \
    test -f /out/lib/timescaledb.so; \
    grep -q "^default_version = '${TIMESCALEDB_VERSION}'" \
        /out/share/extension/timescaledb.control \
        || { echo "control default_version is not ${TIMESCALEDB_VERSION}" >&2; \
             cat /out/share/extension/timescaledb.control >&2; exit 1; }

FROM scratch
COPY --from=build /out/ /
