# Multi-stage: npm (build toolchain with known CVEs in the base image bundle)
# never ships in the runtime image. Only node + app node_modules remain.
FROM node:22-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9
# Strip npm toolchain (bundled CVEs, unneeded at runtime: healthchecks use node fetch).
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY worker.js ./
USER node
EXPOSE 8003
CMD ["node", "worker.js"]
