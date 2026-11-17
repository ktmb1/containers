# rutracker-cf-proxy (rofl3228/rutracker-cf-proxy) with one change to the
# Prowlarr definition it ships: search keywords are capped at 90 characters.
#
# RuTracker's search silently returns nothing for a query of roughly 100+
# characters. Shelfarr builds queries from title + subtitle + author, and a
# Russian non-fiction subtitle alone can run past that - "Откуда берутся дети?
# Краткий путеводитель по переходу из лагеря чайлдфри к тихим радостям
# семейственности Ася Казанцева" is ~120 characters, found 0 results, and the
# same title cut to 88 found the book. See patch-definition.py.
#
# Only the definition changes; the proxy code is upstream's, byte for byte.
# The proxy is the image's own entrypoint, and the patched definition reaches
# Prowlarr through the same `install-definition` command, which home-ops runs
# as an init container in the Prowlarr pod.
#
# Drop this image (point home-ops back at upstream) if upstream adds its own
# length cap.
FROM ghcr.io/rofl3228/rutracker-cf-proxy:0.1.1@sha256:ebf142cfa8d19b21c4432df99dc63dacbf45acac8c364f7f4a283e985491f7f6

# The definition lives inside the installed package, owned by root; upstream's
# USER (appuser, uid 568) is restored straight after.
USER root
COPY patch-definition.py /tmp/patch-definition.py
RUN python /tmp/patch-definition.py && rm /tmp/patch-definition.py
USER appuser
