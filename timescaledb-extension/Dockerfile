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
# The layout is dictated by CNPG and mirrors ghcr.io/cloudnative-pg/pgvector -
# a scratch image with lib/ and share/extension/ at the root. CNPG appends
# those to the operand's dynamic_library_path and extension_control_path.
ARG PG_MAJOR=18
ARG TIMESCALEDB_VERSION=2.29.2

FROM postgres:${PG_MAJOR}-trixie AS build
ARG PG_MAJOR
ARG TIMESCALEDB_VERSION

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        postgresql-server-dev-${PG_MAJOR} libssl-dev libkrb5-dev; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    git clone --depth 1 --branch ${TIMESCALEDB_VERSION} \
        https://github.com/timescale/timescaledb.git /src

WORKDIR /src
# -DAPACHE_ONLY=ON builds only the Apache-2.0 licensed core, leaving out the
# Timescale License (TSL) parts. That keeps the image redistributable and still
# covers hypertables, compression and continuous aggregates.
RUN set -eux; \
    ./bootstrap -DCMAKE_BUILD_TYPE=RelWithDebInfo -DAPACHE_ONLY=ON \
        -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF; \
    cd build && make -j"$(nproc)" && make install

# Collect just the pieces CNPG needs, in the layout it expects.
RUN set -eux; \
    mkdir -p /out/lib /out/share/extension; \
    cp -a "$(pg_config --pkglibdir)"/timescaledb*.so /out/lib/; \
    cp -a "$(pg_config --sharedir)"/extension/timescaledb*.control /out/share/extension/; \
    cp -a "$(pg_config --sharedir)"/extension/timescaledb*.sql /out/share/extension/; \
    ls -la /out/lib /out/share/extension

FROM scratch
COPY --from=build /out/ /
