# Woolworths MCP server (amasolov/woolworths-mcp, a continuation of
# elijah-g/Woolworths-mcp), served over Streamable HTTP for the ktmb1/home-ops
# MCP gateway.
#
# The server speaks stdio only, so supergateway goes in front to turn it into
# HTTP. Everything else - headless by default, the lockfile - lives in the
# source repo now.
FROM node:24-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66 AS build

# A release tag of amasolov/woolworths-mcp, without its leading "v". Renovate
# moves it, and the build matrix's `version`, through the github-releases
# datasource.
ARG WOOLWORTHS_MCP_VERSION=1.1.0

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    mkdir -p /src; \
    curl -fsSL "https://codeload.github.com/amasolov/woolworths-mcp/tar.gz/refs/tags/v${WOOLWORTHS_MCP_VERSION}" \
    | tar -xz --strip-components=1 -C /src; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Puppeteer's postinstall would download its own Chrome (131, from 2024, never
# patched). Skipped: the runtime image uses Debian's chromium instead, which
# Debian security updates - this is a browser that loads a public website.
#
# npm ci fails if the repo's package-lock.json is missing or out of step with
# its package.json, so what is installed is exactly what that tag locked.
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN npm ci --no-audit --no-fund

RUN npm run build && npm prune --omit=dev

FROM node:24-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66

# The stdio-to-HTTP bridge. Pinned; Renovate tracks it through the npm
# datasource (see .renovaterc.json5).
ARG SUPERGATEWAY_VERSION=4.1.0

# chromium from Debian rather than Puppeteer's download - see above.
#
# Deliberately NOT version-pinned, unlike chrony. Chromium in trixie moves to
# a new upstream major through trixie-security every few weeks, each one a
# security release; a pin would turn every one into a PR that has to land
# before the browser is patched. Unpinned, the weekly rebuild takes it, and
# home-ops sees the rebuild as a digest update of the same tag - still a
# reviewable PR there, just not a second one here.
#
# The font
# package is what keeps product pages from rendering as tofu, which matters
# only in that Chrome lays out text it then measures; without any font Chrome
# still starts.
#
# hadolint ignore=DL3008,DL3016
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends chromium fonts-liberation ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    npm install -g --no-audit --no-fund "supergateway@${SUPERGATEWAY_VERSION}"; \
    npm cache clean --force

COPY --from=build /src/dist /app/dist
COPY --from=build /src/node_modules /app/node_modules
COPY --from=build /src/package.json /app/package.json

# Puppeteer reads these at launch: use Debian's binary, and keep its cache and
# Chrome's profile under /tmp, the one writable path under
# readOnlyRootFilesystem.
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    HOME=/tmp \
    NODE_ENV=production

WORKDIR /app

# The image's own `node` user (1000).
USER node

EXPOSE 8000

# --stateful: the server keeps the browser and the captured cookies in the
# process, so every request of one MCP session must reach the same child
# process. Stateless mode starts a fresh child per request - the cookies from
# woolworths_get_cookies would be gone by the next call.
#
# Each session therefore gets its own child and its own Chromium; the session
# timeout reaps both after 30 idle minutes.
ENTRYPOINT ["supergateway", \
    "--stdio", "node /app/dist/index.js", \
    "--outputTransport", "streamableHttp", \
    "--stateful", \
    "--sessionTimeout", "1800000", \
    "--port", "8000", \
    "--healthEndpoint", "/healthz"]
