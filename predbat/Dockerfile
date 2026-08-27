# Predbat, built from upstream source to run outside Home Assistant.
#
# Predbat's supported deployments are a Home Assistant add-on (which needs the
# Supervisor) and a community Docker fork. The add-on is not an option on
# Talos, and the fork (nipar44/predbat_addon) is a third party rebuilding
# someone else's application - so this builds the upstream sources directly,
# from a tag, with the dependency set pinned.
#
# Off the Supervisor, Predbat talks to Home Assistant over the ordinary REST +
# websocket API using ha_url/ha_key in apps.yaml; SUPERVISOR_TOKEN, which the
# add-on relies on, simply does not exist here.
FROM python:3.13-slim-trixie

# The upstream release tag. Renovate tracks this through the github-releases
# datasource (see .renovaterc.json5), so a Predbat release opens a PR here.
ARG PREDBAT_VERSION=v8.53.4

# Predbat's requirements.txt pins only numpy, so an image built today and one
# built next week could otherwise carry different libraries. Everything is
# pinned here instead and Renovate keeps them moving, which means a dependency
# bump is a reviewed PR with a build behind it rather than a surprise in the
# weekly rebuild.
#
# numpy holds upstream's own pin (2.3.5) rather than floating to latest, since
# upstream chose it deliberately and Predbat's numerics are what it pins for.
# ruamel.yaml keeps the 0.18.x line the add-on shipped: 0.19 is a new major,
# and Predbat round-trips apps.yaml through it to preserve the comments - which
# on this deployment carry the entire Powerwall 3 rationale.
#
# hadolint ignore=DL3013
RUN pip install --no-cache-dir \
    "pytz==2026.3.post1" \
    "requests==2.34.2" \
    "pyyaml==6.0.3" \
    "aiofiles==25.1.0" \
    "aiohttp==3.14.3" \
    "aiomqtt==2.5.1" \
    "Jinja2==3.1.6" \
    "ruamel.yaml==0.19.1" \
    "pyjwt==2.13.0" \
    "numpy==2.5.2" \
    "prometheus-client==0.26.0" \
    "protobuf==7.36.0" \
    "pvlib==0.15.2"

# curl for the download, ca-certificates for TLS to GitHub; both are removed
# again in the same layer so neither ships in the final image.
#
# The tarball is used rather than a git clone so the image contains a release,
# not a branch. Predbat's own startup.py would download this at first boot
# into the config volume - that is exactly what is avoided here: it makes the
# running version a property of whenever the volume was first written, needs
# egress to GitHub at runtime, and puts the application inside the backup.
#
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    mkdir -p /opt/predbat; \
    curl -fsSL "https://codeload.github.com/springfall2008/batpred/tar.gz/refs/tags/${PREDBAT_VERSION}" \
    -o /tmp/predbat.tar.gz; \
    tar -xzf /tmp/predbat.tar.gz -C /tmp; \
    cp -a "/tmp/batpred-${PREDBAT_VERSION#v}/apps/predbat/." /opt/predbat/; \
    rm -rf /tmp/predbat.tar.gz "/tmp/batpred-${PREDBAT_VERSION#v}"; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*; \
    # The prediction kernel ships as a prebuilt .so per architecture. This
    # image is linux/amd64 only, so the others are dead weight - and their
    # absence makes a wrong-arch build fail here rather than at runtime.
    find /opt/predbat -name 'prediction_kernel_lib_*.so' \
    ! -name 'prediction_kernel_lib_x86_64.so' -delete; \
    test -f /opt/predbat/prediction_kernel_lib_x86_64.so; \
    test -f /opt/predbat/hass.py

# Send the logs somewhere other than the working directory. Predbat writes its
# logs and its state into the same directory by bare relative filename, and on
# Kubernetes that directory is a replicated PVC where a rotating 10x10MiB
# debug log has no business living. See the script's docstring for why this
# needs a code change rather than a symlink or a different CWD.
COPY patch-log-dir.py /tmp/patch-log-dir.py
RUN python3 /tmp/patch-log-dir.py /opt/predbat && rm /tmp/patch-log-dir.py

# Fail the build if the patched sources do not compile, rather than shipping an
# image that dies on first start.
RUN python3 -m compileall -q /opt/predbat/hass.py /opt/predbat/web.py

# Predbat validates its own install against manifest.yaml on every start. The
# release tarball has no manifest - it is written by Predbat's GitHub
# downloader, the install path this image replaces - so without one Predbat
# calls the GitHub contents API on every start and then fails to write the
# result into root-owned /opt/predbat. Generated last, so it describes the
# files as patched and pruned above rather than as upstream shipped them.
COPY write-manifest.py /tmp/write-manifest.py
RUN python3 /tmp/write-manifest.py /opt/predbat && rm /tmp/write-manifest.py

# /config is the state volume (apps.yaml, predbat_config.json, the ML models,
# cache/) and is the working directory because Predbat resolves all of those
# by bare relative name. /var/log/predbat is expected to be an emptyDir.
ENV PREDBAT_LOG_DIR=/var/log/predbat \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
RUN install -d -o 65532 -g 65532 /config /var/log/predbat

WORKDIR /config

# An arbitrary non-root uid, matching the distroless "nonroot" convention.
# Predbat needs no privileges: it makes outbound HTTP to Home Assistant and
# serves its own web UI on an unprivileged port.
USER 65532:65532

# 5052 is the web UI (the add-on put this behind Home Assistant ingress).
EXPOSE 5052

# Upstream's standalone entrypoint wraps this in a `while(1)` csh loop that
# restarts Predbat after a crash. That is deliberately not reproduced: it
# would hide crashes from Kubernetes, which should be the thing deciding
# whether to restart this pod, and turn a CrashLoopBackOff into a container
# that looks healthy while failing every few seconds.
ENTRYPOINT ["python3", "/opt/predbat/hass.py"]
