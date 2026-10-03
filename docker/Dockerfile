# ─── Stage 1: Haskell backend ─────────────────────────────────
# 9.10.3 is the GHC stack.yaml pins (lts-24.61), so the image's own compiler is
# the one that builds the project. The tag has to be spelled in full:
# "haskell:9.14.1-slim" is not published, only "haskell:9.14.1-slim-bookworm".
FROM haskell:9.10.3-slim-bookworm AS backend

WORKDIR /src
# libsecp256k1 is no longer needed: BIP-340 is pure Haskell
# (core/src/Krivostr/Schnorr.hs), and the only C in the build is the sqlite3
# amalgamation sqlite-simple compiles itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# stack.yaml.lock is copied too: it is what pins the snapshot and the GHC, so a
# build without it can resolve differently from the one the tests ran.
COPY stack.yaml stack.yaml.lock ./
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
