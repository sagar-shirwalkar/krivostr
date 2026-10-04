# ─── Stage 1: Haskell backend ─────────────────────────────────
# 9.10.3 is the GHC stack.yaml pins (lts-24.61), so the image's own compiler is
# the one that builds the project. The tag has to name a published image:
# "haskell:9.14.1-slim" does not exist, only per-distro tags such as
# "haskell:9.10.3-slim-bookworm".
FROM haskell:9.10.3-slim-bookworm@sha256:152bf2650eecf6fd9bdbb6c34c2722637d25542566825a6740771a0c6f403fe2 AS backend

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
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS ui

WORKDIR /ui
RUN corepack enable && corepack prepare pnpm@9 --activate

COPY ui/package.json ui/pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install

COPY ui/ .
RUN pnpm build

# ─── Stage 3: Runtime ─────────────────────────────────────────
# Debian, not Alpine: the backend stage is a glibc image, so the binary it
# produces needs glibc plus the shared libraries GHC links against (libgmp,
# zlib). An Alpine/musl runtime cannot load it -- there is no ld-linux and no
# libgmp, so the process dies before main.
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libgmp10 zlib1g tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=backend /out/krivostr /app/krivostr
COPY --from=ui /ui/dist /app/static

EXPOSE 8081

ENTRYPOINT ["/usr/bin/tini", "--"]
# Bind to 0.0.0.0 so the port is reachable outside the container.
CMD ["/app/krivostr", "serve", "--port", "8081", "--host", "0.0.0.0", "--static", "/app/static"]
