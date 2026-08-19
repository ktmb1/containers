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
ARG PG_OPERAND_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie

# The layout is dictated by CNPG and mirrors ghcr.io/cloudnative-pg/pgvector -
# a scratch image with lib/ and share/extension/ at the root. CNPG appends
# those to the operand's dynamic_library_path and extension_control_path.
#
# The image ships MORE THAN ONE TimescaleDB version, and that is deliberate.
# TimescaleDB's loader reads the version recorded in the database's pg_extension
# catalog and dlopen()s exactly that timescaledb-<version>.so. If the databases
# are on 2.25.2 and the image carries only 2.29.2, *every* session fails with
# `could not access file "timescaledb-2.25.2"` - including a bare SELECT 1,
# because the loader runs before any query. The third-party Postgres image this
# replaced happened to carry nine versions, so the mismatch only surfaced when
# an instance moved to the official operand.
#
# So: keep the version the databases are actually on until they have been
# upgraded with ALTER EXTENSION timescaledb UPDATE. Only drop a version from
# TIMESCALEDB_VERSIONS once no database still records it - check with
#   SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
# in every database, on every cluster that mounts this image.
ARG PG_MAJOR=18

# The version whose control file wins: what CREATE EXTENSION timescaledb
# installs by default, and what ALTER EXTENSION ... UPDATE targets.
ARG TIMESCALEDB_VERSION=2.29.2

# Every version whose .so is built into the image, space separated. Must contain
# TIMESCALEDB_VERSION. Any additional entry is a legacy version kept solely so
# databases still on it can load, and therefore be upgraded.
ARG TIMESCALEDB_VERSIONS="2.25.2 2.29.2"

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
RUN set -eux; \
    apt-get update; \
    pgver="$(dpkg-query -W -f='${Version}' "postgresql-${PG_MAJOR}")"; \
    echo "building against postgresql-${PG_MAJOR} ${pgver}"; \
    apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        libssl-dev libkrb5-dev \
        "postgresql-server-dev-${PG_MAJOR}=${pgver}"; \
    rm -rf /var/lib/apt/lists/*

# Build each requested version in turn, all into the same prefix. The .so files
# are version-suffixed so they accumulate rather than collide, but the shared
# unsuffixed files (the timescaledb.so loader, timescaledb.control) are
# overwritten by each pass. TIMESCALEDB_VERSION is therefore built LAST, so its
# control file - and thus default_version - is the one that survives.
#
# -DAPACHE_ONLY=ON builds only the Apache-2.0 licensed core, leaving out the
# Timescale License (TSL) parts. That keeps the image redistributable and still
# covers hypertables, compression and continuous aggregates.
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
        ./bootstrap -DCMAKE_BUILD_TYPE=RelWithDebInfo -DAPACHE_ONLY=ON \
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
# database: every requested version must have produced its own .so, and the
# surviving control file must name TIMESCALEDB_VERSION as default_version.
RUN set -eux; \
    for v in ${TIMESCALEDB_VERSIONS}; do \
        test -f "/out/lib/timescaledb-$v.so" \
            || { echo "missing /out/lib/timescaledb-$v.so" >&2; exit 1; }; \
    done; \
    test -f /out/lib/timescaledb.so; \
    grep -q "^default_version = '${TIMESCALEDB_VERSION}'" \
        /out/share/extension/timescaledb.control \
        || { echo "control default_version is not ${TIMESCALEDB_VERSION}" >&2; \
             cat /out/share/extension/timescaledb.control >&2; exit 1; }

FROM scratch
COPY --from=build /out/ /
