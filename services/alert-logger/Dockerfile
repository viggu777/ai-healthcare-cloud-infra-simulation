# P1.4 — local alert sink. Zero npm dependencies (bare node http), so the
# build stage only enforces the non-root runtime + toolchain strip.
FROM node:22-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9
# Strip npm toolchain (same rationale as the other custom services: unneeded at
# runtime — healthcheck uses node fetch; see docs/SECURITY.md F5).
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
WORKDIR /app
COPY server.js ./
USER node
EXPOSE 9089
CMD ["node", "server.js"]
