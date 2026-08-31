# PostGIS as a CloudNativePG *extension image volume*, alongside
# timescaledb-extension, so db1 can host the Home Assistant LTSS table without
# leaving the official CNPG operand.
#
# LTSS stores `location geometry(Point,4326)`, a PostGIS type, so the extension
# has to exist on the target before that table can be restored at all.
#
# Unlike TimescaleDB this is NOT compiled from source: pgdg publishes
# postgresql-${PG_MAJOR}-postgis-3 built against the same Postgres packaging the
# operand uses, so the sane thing is to install that and repackage it into the
# layout CNPG mounts.
ARG PG_OPERAND_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie

ARG PG_MAJOR=18

# What CREATE EXTENSION postgis installs. Recorded here so the published tag and
# the contents agree; the actual version comes from the pgdg package.
ARG POSTGIS_VERSION=3.6.4

FROM ${PG_OPERAND_IMAGE} AS build
ARG PG_MAJOR
ARG POSTGIS_VERSION

USER 0

# The interesting constraint. CNPG adds the image's lib/ to
# dynamic_library_path, which is how Postgres finds postgis-3.so - but that path
# means nothing to the *dynamic linker*, which then has to resolve
# postgis-3.so's own NEEDED entries (libgeos_c, libproj, ...). The operand ships
# none of those, LD_LIBRARY_PATH is empty there, and /etc/ld.so.conf.d does not
# mention /extensions. So the shared libraries have to travel inside this image
# too, and the consuming Cluster must set spec.postgresql.extensions[].
# ld_library_path - see the README.
#
# postgresql-${PG_MAJOR}-postgis-3 alone pulls in 95 packages, because
# postgis_raster links against GDAL, which drags in HDF5, poppler, MariaDB and
# the DejaVu fonts. None of that is reachable from the core geometry type, so
# the raster and sfcgal modules are deliberately dropped below and only the
# core + topology .so files are shipped. That is the difference between a ~66MB
# image and a ~400MB one.
#
# The snapshot of pre-existing libraries is taken BEFORE the install so the copy
# step can tell "library the operand already has" from "library postgis added".
# Copying the former would shadow the operand's own, security-updated copies
# with frozen ones from this image, which is exactly the failure mode a
# bundled-dependency image invites.
RUN set -eux; \
    apt-get update; \
    find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name '*.so*' 2>/dev/null \
      | xargs -n1 basename | sort -u > /tmp/before.txt; \
    apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}-postgis-3" \
        "postgresql-${PG_MAJOR}-postgis-3-scripts"; \
    find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name '*.so*' 2>/dev/null \
      | xargs -n1 basename | sort -u > /tmp/after.txt; \
    comm -13 /tmp/before.txt /tmp/after.txt > /tmp/new.txt; \
    rm -rf /var/lib/apt/lists/*

# Collect into the layout CNPG expects: lib/ and share/extension/ at the root,
# mirroring ghcr.io/cloudnative-pg/pgvector. proj/ is extra and is pointed at by
# PROJ_DATA - PROJ needs its grid database (proj.db) or every coordinate
# operation fails at runtime, and the operand has no /usr/share/proj.
#
# cp -aL, not cp -a: Debian routes the unversioned control files through
# /etc/alternatives (postgis.control -> /etc/alternatives/postgresql-18-postgis
# .control), which does not exist inside this scratch image. Preserving those
# symlinks produces a file that `ls` shows and `cat` cannot read, and Postgres
# reports the extension as simply "not available" - a confusing failure the
# assertion below now makes impossible.
RUN set -eux; \
    mkdir -p /out/lib /out/share/extension /out/proj; \
    L="$(pg_config --pkglibdir)"; S="$(pg_config --sharedir)"; \
    cp -aL "$L"/postgis-3.so "$L"/postgis_topology-3.so /out/lib/; \
    for f in "$S"/extension/postgis*.control "$S"/extension/postgis*.sql; do \
        case "$f" in *raster*|*sfcgal*) continue;; esac; \
        [ -e "$f" ] && cp -aL "$f" /out/share/extension/; \
    done; \
    for so in /out/lib/*.so; do ldd "$so" | awk '/=> \//{print $3}'; done \
      | sort -u > /tmp/queue.txt; \
    while [ -s /tmp/queue.txt ]; do \
        lib="$(head -1 /tmp/queue.txt)"; sed -i 1d /tmp/queue.txt; \
        base="$(basename "$lib")"; \
        grep -qx "$base" /tmp/new.txt || continue; \
        [ -e "/out/lib/$base" ] && continue; \
        cp -aL "$lib" /out/lib/; \
        ldd "$lib" 2>/dev/null | awk '/=> \//{print $3}' >> /tmp/queue.txt || true; \
    done; \
    cp -a /usr/share/proj/. /out/proj/; \
    ls -la /out/lib

# Fail the build rather than publish an image that cannot load. Each of these
# corresponds to a way this went wrong while it was being written.
RUN set -eux; \
    test -f /out/lib/postgis-3.so; \
    test -s /out/share/extension/postgis.control; \
    test -f /out/proj/proj.db; \
    grep -q "^default_version = '${POSTGIS_VERSION}'" \
        /out/share/extension/postgis.control \
        || { echo "postgis.control default_version is not ${POSTGIS_VERSION}" >&2; \
             cat /out/share/extension/postgis.control >&2; exit 1; }; \
    if [ -n "$(find /out -xtype l)" ]; then \
        echo "dangling symlinks would ship in this image:" >&2; \
        find /out -xtype l >&2; exit 1; \
    fi; \
    for so in /out/lib/postgis-3.so /out/lib/postgis_topology-3.so; do \
        LD_LIBRARY_PATH=/out/lib ldd "$so" | grep -q "not found" \
            && { echo "unresolved NEEDED in $so:" >&2; \
                 LD_LIBRARY_PATH=/out/lib ldd "$so" >&2; exit 1; }; \
    done; \
    test ! -e /out/lib/postgis_raster-3.so

FROM scratch
COPY --from=build /out/ /
