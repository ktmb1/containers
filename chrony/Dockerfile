# chrony as a serve-only NTP server for the LAN.
#
# There is no official chrony container image - upstream ships source only - so
# rather than depend on one of the several third-party wrapper images (each with
# its own entrypoint generating a chrony.conf from environment variables), this
# builds Debian's packaged chrony and takes its config from the consumer.
#
# The image is deliberately serve-only: it answers NTP for LAN devices and never
# touches a clock. See the ENTRYPOINT note on -x.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

# The exact Debian package version, passed from the build matrix so Renovate's
# `deb` datasource has a single place to bump. Pinning it means the published
# tag describes what is actually inside the image rather than approximating it.
#
# The default is a convenience for local builds; CI always passes this
# explicitly. If Debian supersedes this version the build fails loudly with
# "Version '...' for 'chrony' was not found" - which is the intended behaviour:
# it means the pin is stale and Renovate has a PR waiting, rather than the
# image silently drifting to a version nobody recorded.
ARG CHRONY_VERSION=4.6.1-3+deb13u2

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends "chrony=${CHRONY_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    # The packaged config targets a full system: it pulls in debian.pool.ntp.org,
    # drives the RTC, and logs to a directory that does not exist here. The
    # consumer mounts its own over this path, so remove Debian's - a failed mount
    # then surfaces as chronyd refusing to start rather than as this container
    # quietly serving Debian's defaults to the LAN.
    && rm -f /etc/chrony/chrony.conf \
    # /run/chrony is created by systemd-tmpfiles on a real boot, which never runs
    # in a container. Without it chronyd exits immediately with
    # "Could not open /run/chrony/chronyd.pid". 0750 owned by _chrony is what the
    # daemon expects once it has dropped privileges.
    && install -d -o _chrony -g _chrony -m 0750 /run/chrony

# No USER directive, deliberately. chronyd must start as root - it binds UDP/123
# and installs a seccomp filter - and refuses to run otherwise with
# "Fatal error : Not superuser". It drops to the unprivileged _chrony user
# itself via -u below, which is the supported way round; the package already
# owns /var/lib/chrony as that user, so the drift file stays writable after the
# drop. Verified with `ps` in a running container.
EXPOSE 123/udp

# -u _chrony: drop privileges once the socket is bound.
# -d: log to stderr, stay in the foreground.
# -L 0: log informational messages and worse.
# -x: never discipline the system clock. A container shares the host's time
#   namespace, so without this chronyd would steer the *node's* clock - which on
#   a Talos node is already owned by the node's own chronyd. This costs nothing
#   in served accuracy: chronyd still tracks its sources and still serves the
#   real upstream stratum, applying the offset it has computed to its replies
#   rather than to the local clock. (A `local` directive in chrony.conf breaks
#   that - with -x it pins the served stratum at 10 - which is what verify.sh
#   asserts against.)
ENTRYPOINT ["/usr/sbin/chronyd", "-u", "_chrony", "-x", "-d", "-L", "0"]
