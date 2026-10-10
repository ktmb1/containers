# Woolworths MCP server (elijah-g/Woolworths-mcp), served over Streamable
# HTTP for the ktmb1/home-ops MCP gateway.
#
# Upstream publishes no image, speaks stdio only, and ships no lockfile. So
# this builds a pinned commit with a lockfile generated here (package-lock.json
# next to this file), and puts supergateway in front to turn stdio into HTTP.
FROM node:22-trixie-slim@sha256:154ba2f4d6fec323d28e4f4bb86bba4677f1223391a1979cf521304e03a98dfa AS build

# Upstream has no releases or tags - this is the head of main. A commit, not a
# branch, so the image's contents are a property of this file and not of when
# it was built.
ARG WOOLWORTHS_MCP_REF=04ca8549627c6455692dee811a786189a1593076

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    mkdir -p /src; \
    curl -fsSL "https://codeload.github.com/elijah-g/Woolworths-mcp/tar.gz/${WOOLWORTHS_MCP_REF}" \
    | tar -xz --strip-components=1 -C /src; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Upstream's package.json is all caret ranges with no lockfile, so two builds a
# week apart could ship different MCP SDKs. The lockfile here was generated
# from upstream's own package.json and is what `npm ci` installs; the cmp
# fails the build if upstream's package.json moves at a ref bump and the
# lockfile was not regenerated with it.
COPY package.json package-lock.json /tmp/lock/
RUN cmp /tmp/lock/package.json package.json && cp /tmp/lock/package-lock.json .

# Puppeteer's postinstall would download its own Chrome (131, from 2024, never
# patched). Skipped: the runtime image uses Debian's chromium instead, which
# Debian security updates - this is a browser that loads a public website.
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN npm ci --no-audit --no-fund

# Force headless. Upstream defaults woolworths_open_browser to a VISIBLE
# browser, so a human can log in by hand, and lets the caller choose. There is
# no display in a pod: a non-headless launch dies with "Missing X server", and
# the default is exactly what an LLM calling the tool with no arguments gets.
# The grep fails the build if upstream reworded the line and the patch no
# longer applies, rather than shipping an image that crashes on first use.
RUN grep -qxF '  const headless = args.headless ?? false;' src/index.ts \
    && sed -i 's/^  const headless = args.headless ?? false;$/  const headless = true;/' src/index.ts \
    && grep -qxF '  const headless = true;' src/index.ts

RUN npm run build && npm prune --omit=dev

FROM node:22-trixie-slim@sha256:154ba2f4d6fec323d28e4f4bb86bba4677f1223391a1979cf521304e03a98dfa

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
