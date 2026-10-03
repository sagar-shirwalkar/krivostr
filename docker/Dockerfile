# ─── Stage 1: Haskell backend ─────────────────────────────────
FROM haskell:9.14.1-slim AS backend

WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
      libsecp256k1-dev pkg-config ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY stack.yaml ./
COPY core/ core/
COPY client/ client/
RUN stack build --copy-bins --local-bin-path /out

# ─── Stage 2: UI ──────────────────────────────────────────────
FROM node:22-alpine AS ui

WORKDIR /ui
RUN corepack enable && corepack prepare pnpm@9 --activate

COPY ui/package.json ui/pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install

COPY ui/ .
RUN pnpm build

# ─── Stage 3: Runtime ─────────────────────────────────────────
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tini

WORKDIR /app
COPY --from=backend /out/krivostr /app/krivostr
COPY --from=ui /ui/dist /app/static

EXPOSE 8081

ENTRYPOINT ["/sbin/tini", "--"]
# The bridge serves the UI, the /ws endpoint and everything else on one port.
CMD ["/app/krivostr", "serve", "--port", "8081", "--static", "/app/static"]
