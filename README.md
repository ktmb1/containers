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
| `predbat`               | this repo (`Dockerfile`)            | Home battery prediction and control, off the Supervisor |
| `aiolists`              | `amasolov/AIOLists` (`deploy`)      | AIOLists Stremio addon, from our fork                 |
| `stremio-web`           | `Stremio/stremio-web` (release tag) | Stremio web UI                                        |

Only images whose own directory changed are built on a push; a change to
[`build.yaml`](.github/workflows/build.yaml) rebuilds everything, since it
carries the build args and verify steps. The weekly cron and a manual
`workflow_dispatch` rebuild everything unconditionally. Pull requests build
without pushing.

Rebuilding an unchanged image is not free: it republishes the same tag with a
new digest — the contents are identical apart from build timestamps — and each
of those becomes a Renovate PR in `ktmb1/home-ops`, which is noise a real
change would have to be spotted among.

Base-image CVE fixes still land without a code change, but by a better route
than a blind rebuild: Renovate pins base images by digest here, so a rebased
`debian:trixie-slim` or CNPG operand opens a PR against the Dockerfile that
pins it — which makes that image changed, and rebuilds exactly it.

Renovate runs unscheduled and every base image is digest-pinned, so a rebased
upstream tag — a Debian security rebuild of `trixie-slim`, a CNPG operand
repush — is an update: it opens a PR, `build.yaml` builds and verifies it, and
it automerges.

A digest-only rebuild republishes the *same* tag with new contents, since the
tag comes from the matrix `version`. That is fine for `ktmb1/home-ops`, which
pins every `ghcr.io/ktmb1/*` image by digest alongside the tag and so sees the
rebuild as a digest update. It does mean the tag alone does not identify the
bytes: a consumer pinning by tag would swap contents silently on the next pull.

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

## predbat

[Predbat](https://github.com/springfall2008/batpred) predicts home battery
behaviour and drives charging against a tariff. It is consumed by
`ktmb1/home-ops` as the `smarthome/predbat` app, controlling the Powerwall 3
through Home Assistant.

Upstream supports two deployments: a Home Assistant add-on, which needs the
Supervisor and so cannot run on Talos, and a community Docker fork
(`nipar44/predbat_addon`) — a third party rebuilding someone else's
application. This builds the upstream sources directly, from a release tag,
with the dependency set pinned.

Off the Supervisor there is no `SUPERVISOR_TOKEN`, so Predbat talks to Home
Assistant over the ordinary REST + websocket API using `ha_url` and `ha_key`
in `apps.yaml`. That is a supported upstream path, not a workaround.

Three things about the image are deliberate:

**The logs are redirected off the state volume.** Predbat writes its logs *and*
its state — `predbat_config.json`, the ML models, `cache/` — into the working
directory, by bare relative filename. On the cluster that directory is a
replicated PVC, and the logs dominate it: on the add-on this replaced, 95MiB of
`predbat.log` + `predbat.1-9.log` against 56MiB of real state. `patch-log-dir.py`
routes the eight log call sites through `$PREDBAT_LOG_DIR`, which the
HelmRelease points at an `emptyDir`. With the variable unset every path is
byte-identical to upstream, which is what keeps the patch safe across version
bumps — and each substitution is asserted, so an upstream refactor fails the
build instead of silently reverting to the PVC.

This cannot be done from outside the code, which is worth recording because
both alternatives look like they work:

- A **symlink farm** does not survive rotation. `os.rename("predbat.log",
  "predbat.1.log")` renames the *symlink*, and the `open("predbat.log", "w")`
  that follows creates a real file on the PVC — so logs migrate back after the
  first 10MiB. `verify.sh` is run against a deliberately-broken symlink build
  to confirm it catches exactly this.
- **Pointing the CWD at the log directory** moves the state off the PVC
  instead. Only `apps.yaml` is relocatable (`PREDBAT_APPS_FILE`); the config
  JSON, the models and `cache/` are not.

**The application is baked into the image, not downloaded at runtime.**
Predbat's own `startup.py` fetches the latest release from GitHub into the
config volume on first boot. That makes the running version a property of
whenever the volume was created, needs egress to GitHub at runtime, and puts
the application inside the backup. The Dockerfile downloads a pinned tag
instead, and Renovate tracks it.

**The install self-check does not need the network.** Predbat validates the
files next to `hass.py` against a `manifest.yaml` on every start. The release
tarball has no manifest — it is written by Predbat's GitHub downloader, the
install path this image replaces — so without one Predbat calls the GitHub
contents API on *every* start and then fails to write the result into
root-owned `/opt/predbat`, leaving an error that reads like a fault.
`write-manifest.py` generates it at build time from the files actually in the
image, which matters because the image is not a byte-identical copy of the
tarball: the non-amd64 prediction kernels are deleted and two files are
patched, so an upstream manifest would report missing files and SHA mismatches
on every start. The image starts clean with `--network none`.

**There is no restart loop.** Upstream's standalone entrypoint wraps Predbat in
a `while(1)` csh loop. That is not reproduced: Predbat exits cleanly when it
cannot reach Home Assistant, and the loop would turn that into a container that
looks healthy while failing every few seconds, instead of a visible
`CrashLoopBackOff`.

`verify.sh` starts the image against a stub Home Assistant and checks where the
bytes land — including across a forced rotation, which is the case that
separates a working redirect from one that has quietly reverted to the PVC. A
build alone cannot show this: a broken redirect produces an image that starts
perfectly and writes 100MiB onto the volume it was meant to keep clean.

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
