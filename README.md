# containers

Custom container images for the [ktmb1](https://github.com/ktmb1) homelab,
built and published to GHCR by [`.github/workflows/build.yaml`](.github/workflows/build.yaml).

Two kinds of build live here:

- **Images with a `Dockerfile` in this repo** — one directory each, built by
  [`build.yaml`](.github/workflows/build.yaml). Add a matrix entry to add one.
- **Images built from someone else's source** — a dedicated workflow checks out
  the upstream repo and builds its Dockerfile. These have no directory here.

| Image                   | Built from                          | Purpose                                               |
| ----------------------- | ----------------------------------- | ----------------------------------------------------- |
| `timescaledb-extension` | this repo (`Dockerfile`)            | TimescaleDB as a CloudNativePG extension image volume |
| `chrony`                | this repo (`Dockerfile`)            | Serve-only NTP server for the LAN                     |
| `aiolists`              | `amasolov/AIOLists` (`deploy`)      | AIOLists Stremio addon, from our fork                 |
| `stremio-web`           | `Stremio/stremio-web` (release tag) | Stremio web UI                                        |

Images are rebuilt weekly so base-image CVE fixes land without a code change.
Pull requests build without pushing.

## timescaledb-extension

CloudNativePG 1.30 can mount extensions into the Postgres operand from OCI
images (`Cluster.spec.postgresql.extensions`), which means a cluster can run the
official `ghcr.io/cloudnative-pg/postgresql` operand and still get an extension
that image does not ship.

Nobody publishes TimescaleDB in that form — CNPG ships `pgvector` and `pgaudit`
only, and Timescale ships whole Postgres images — so this builds it.

The image is `FROM scratch` with `lib/` and `share/extension/` at the root,
mirroring `ghcr.io/cloudnative-pg/pgvector`. It is built `-DAPACHE_ONLY=ON`, so
it carries only the Apache-2.0 licensed core (hypertables, compression,
continuous aggregates) and none of the Timescale-License parts.

Consumed by `ktmb1/home-ops` as:

```yaml
spec:
    imageName: ghcr.io/cloudnative-pg/postgresql:18.3-standard-trixie
    postgresql:
        extensions:
            - name: timescaledb
              image:
                  reference: ghcr.io/ktmb1/timescaledb-extension:2.29.2-18
        shared_preload_libraries:
            - timescaledb
```

`shared_preload_libraries` is still required: the volume supplies the `.so` on
`dynamic_library_path`, but the library must be preloaded for Postgres to start
once anything references it.

The extension is compiled **against the operand image itself**, not Docker Hub's
`postgres`. A TimescaleDB `.so` links against Postgres server internals that
change between minor releases, and `postgres:18-trixie` floats ahead of the
operand — it was 18.6 while the operand was 18.3 — so an extension built there
loads with `undefined symbol: palloc0_mul` and Postgres refuses to start. The
build stays green throughout. The `operand` matrix entry in
[`build.yaml`](.github/workflows/build.yaml) must therefore match the
`Cluster.spec.imageName` the cluster runs.

Every build then mounts the extension into that operand and checks each shipped
version actually loads: `CREATE EXTENSION` at that exact version, a plain query
(which is what fails for *every* session when a `.so` is missing), a hypertable
round-trip, and — for legacy versions — `ALTER EXTENSION ... UPDATE` to the
default with the data intact. Nothing is pushed until that passes.

## chrony

A serve-only NTP server, so LAN devices can get time from something on the
cluster instead of reaching the internet themselves. Consumed by `ktmb1/home-ops`
as the `network/chrony` app, on a pinned LoadBalancer address.

There is no official chrony container image — upstream ships source only — and
the third-party wrappers all generate `chrony.conf` from environment variables
in their own entrypoint. This builds Debian's packaged chrony instead and takes
the config from the consumer, so what the daemon reads is whatever the
HelmRelease mounted and nothing else.

Two things about it are deliberate and easy to undo by accident:

**It runs `chronyd -x` and is not granted `CAP_SYS_TIME`.** A container shares
the host's time namespace, so a chrony that disciplines "its" clock is really
disciplining the *node's* clock — the one Talos' own chronyd already owns. `-x`
costs nothing in served accuracy: chronyd still tracks its sources and still
serves the real upstream stratum, applying the offset it has computed to its
replies rather than to the local clock. Measured at stratum 4 with refid
`162.159.200.1`, stable across a multi-minute soak.

**Its `chrony.conf` must not contain a `local` directive.** Combined with `-x`
that pins the served stratum at 10 — chronyd keeps tracking Cloudflare at
microsecond accuracy but answers clients from its own reference, so the source
looks far worse than it is. `verify.sh` asserts the served stratum is below 10
for exactly this reason.

The image pins the exact Debian package version (`ARG CHRONY_VERSION`), and
Renovate tracks it through the `deb` datasource against the trixie index, so a
Debian security update opens a PR here instead of arriving unannounced in the
weekly rebuild. Upstream chrony is frozen within a Debian stable release, so
what actually moves is the packaging revision — `4.6.1-3+deb13u2` → `-3+deb13u3`.
A stale pin fails the build loudly (`Version '...' for 'chrony' was not found`)
rather than letting the image drift to a version the tag does not name. The
published tag is that version with `+` mapped to `_`, since `+` is not a legal
OCI tag character.

`verify.sh` starts the built image with the consuming pod's capability set,
waits for synchronisation, and queries it as a real NTP client. Every failure
this image hit in development produced an image that built perfectly and failed
at runtime, so the build alone is not evidence.

## aiolists

Built from our fork (`amasolov/AIOLists`, `deploy` branch), which carries a
search-encoding fix that has no path into an upstream published image.
Temporary: once [SebastianMorel/AIOLists#102](https://github.com/SebastianMorel/AIOLists/pull/102)
merges and appears upstream, point the HelmRelease back at the upstream image
and delete the workflow.

Builds on demand, or when the fork pushes to `deploy` and triggers it:

```bash
gh api repos/ktmb1/containers/dispatches -f event_type=aiolists-rebuild
```

## stremio-web

Built weekly from the latest `Stremio/stremio-web` release tag. The run is a
no-op when that tag is already in GHCR, so it only builds on a real release.
Renovate then opens a PR in `ktmb1/home-ops` to bump the pin.
