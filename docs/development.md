# Development

See the [README](../README.md) for setup. This file covers day-to-day
workflow.

## Backend

```bash
stack build --fast          # build
stack test                  # test
stack test --coverage       # coverage (HPC enforces 80%)
stack ghci core             # REPL
```

## UI

```bash
cd ui
pnpm install
pnpm dev                    # Vite dev server on :5173
pnpm test                   # unit tests (jsdom)
pnpm test:browser           # component tests (real Chromium)
pnpm coverage               # coverage (v8, 80% enforced)
```

## Full build

```bash
make build      # stack + pnpm
make test       # both suites
make coverage   # both coverage reports
```

## Releasing

1. Bump the version in core/package.yaml, client/package.yaml,
ui/package.json, and stack.yaml.
2. Update CHANGELOG.md.
3. Tag and push.
4. CI builds the Docker image and pushes to the registry.

---

##  `.github/workflows/ci.yml`

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  backend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: haskell-actions/setup@v2
        with:
          ghc-version: '9.14.1'
          cabal-version: '3.18.1.0'
      - uses: freckle/stack-action@v5
      - run: stack build --fast
      - run: stack test --coverage
      - run: hpc report --all

  ui:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm
          cache-dependency-path: ui/pnpm-lock.yaml
      - working-directory: ui
        run: pnpm install --frozen-lockfile
      - working-directory: ui
        run: pnpm typecheck
      - working-directory: ui
        run: pnpm test
      - working-directory: ui
        run: pnpm exec playwright install --with-deps chromium
      - working-directory: ui
        run: pnpm test:browser
      - working-directory: ui
        run: pnpm coverage

  docker:
    runs-on: ubuntu-latest
    needs: [backend, ui]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - run: docker build -f docker/Dockerfile -t krivostr:ci .
```

## Makefile

```makefile
.PHONY: all build build-backend build-ui test test-backend test-ui test-browser \
        coverage coverage-backend coverage-ui typecheck docker docker-down clean

all: build

# ─── Build ────────────────────────────────────────────────────
build: build-backend build-ui

build-backend:
	stack build --fast

build-ui:
	cd ui && pnpm install --frozen-lockfile && pnpm build

# ─── Test ─────────────────────────────────────────────────────
test: test-backend test-ui test-browser

test-backend:
	stack test

test-ui:
	cd ui && pnpm test

test-browser:
	cd ui && pnpm test:browser

# ─── Coverage ─────────────────────────────────────────────────
coverage: coverage-backend coverage-ui

coverage-backend:
	stack test --coverage
	hpc report --all > coverage.txt
	@echo "── Backend coverage written to coverage.txt"

coverage-ui:
	cd ui && pnpm coverage

# ─── Typecheck ────────────────────────────────────────────────
typecheck:
	cd ui && pnpm typecheck

# ─── Docker ───────────────────────────────────────────────────
docker:
	docker build -f docker/Dockerfile -t krivostr:latest .

docker-down:
	docker compose -f docker/docker-compose.yml down

# ─── Clean ────────────────────────────────────────────────────
clean:
	stack clean
	rm -rf ui/dist ui/node_modules ui/coverage coverage.txt
```

## docker/Dockerfile (updated for bridge + static)

```
# ─── Stage 1: Haskell backend ─────────────────────────────────
FROM haskell:9.14.1-slim AS backend

WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
      libsecp256k1-dev libsqlite3-dev pkg-config ca-certificates zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

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

RUN apk add --no-cache ca-certificates sqlite-libs libsecp256k1 tini

WORKDIR /app
COPY --from=backend /out/krivostr /app/krivostr
COPY --from=ui /ui/dist /app/static

ENV KRIVOSTR_STATIC_DIR=/app/static
ENV KRIVOSTR_DB=/data/events.db
VOLUME ["/data"]

EXPOSE 8081
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/krivostr"]
```

## docker/docker-compose.yml

```yaml
services:
  krivostr:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: krivostr:latest
    ports:
      - "8081:8081"
    environment:
      KRIVOSTR_LOG_LEVEL: info
      KRIVOSTR_PORT: 8081
      KRIVOSTR_STATIC_DIR: /app/static
      KRIVOSTR_DB: /data/events.db
    volumes:
      - krivostr-data:/data
    restart: unless-stopped

volumes:
  krivostr-data:
```
