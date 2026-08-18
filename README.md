# containers

Custom container images for the [ktmb1](https://github.com/ktmb1) homelab,
built and published to GHCR by [`.github/workflows/build.yaml`](.github/workflows/build.yaml).

Each image is one directory containing a `Dockerfile`. To add one, create the
directory and add a matrix entry to the build workflow.

| Image                    | Purpose                                                        |
| ------------------------ | -------------------------------------------------------------- |
| `timescaledb-extension`  | TimescaleDB as a CloudNativePG extension image volume           |

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
