.PHONY: all build build-backend build-ui linux-binary test test-backend test-ui \
        test-ui-browser coverage coverage-backend coverage-ui docker docker-down \
        verify-version clean

VERSION := $(shell sed -n 's/^version:[[:space:]]*//p' client/package.yaml | head -1)
# A Cabal version carries a fourth component that a release tag has no use for:
# 0.4.0.0 is packaged, v0.4.0 is the tag.
RELEASE_VERSION := $(word 1,$(subst ., ,$(VERSION))).$(word 2,$(subst ., ,$(VERSION))).$(word 3,$(subst ., ,$(VERSION)))

all: build

# ─── Build ────────────────────────────────────────────────────
build: build-backend build-ui

build-backend:
	stack build --fast

build-ui:
	cd ui && pnpm install --frozen-lockfile && pnpm build

# The Linux release binary, built and checked inside Docker so the result is
# the same on a laptop and on a release runner. Depends on glibc alone; see
# docker/Dockerfile.linux for why it is not fully static.
linux-binary:
	docker build -f docker/Dockerfile.linux --target build -t krivostr:linux-build .
	mkdir -p dist
	cid=$$(docker create krivostr:linux-build); \
	  docker cp "$$cid":/out/krivostr dist/krivostr; \
	  docker rm "$$cid" > /dev/null; \
	  chmod +x dist/krivostr; \
	  file dist/krivostr

# ─── Test ─────────────────────────────────────────────────────
test: test-backend test-ui

test-backend:
	stack test

# Unit and browser are separate vitest projects; running only `pnpm test` left
# the 15 browser tests (real WebSocket relay behaviour) unrun.
#
# `pnpm install` fetches the Playwright driver, not the browser, so the install
# step is here too: without it a fresh clone fails with "Executable doesn't
# exist at .../chrome-headless-shell". Add --with-deps on CI, where the system
# libraries are missing too and sudo is available.
test-ui:
	cd ui && pnpm install --frozen-lockfile \
	  && pnpm exec playwright install chromium \
	  && pnpm test && pnpm test:browser

test-ui-browser:
	cd ui && pnpm test:browser

# ─── Coverage ─────────────────────────────────────────────────
coverage: coverage-backend coverage-ui

coverage-backend:
	stack test --coverage
	@# Report first, gate second: the threshold is above the measured number
	@# today, and a failing gate should still leave the report on disk to read.
	./scripts/hpc-coverage.py > coverage.txt
	@echo "── Backend coverage written to coverage.txt"
	./scripts/check-coverage.sh

coverage-ui:
	cd ui && pnpm coverage

# ─── Release ──────────────────────────────────────────────────
# The release workflow does this too; it is here so a bad tag is caught before
# it is pushed rather than after the workflow fails.
verify-version:
	@test -n "$(TAG)" || { echo "usage: make verify-version TAG=v$(RELEASE_VERSION)"; exit 1; }
	@test "$(TAG)" = "v$(RELEASE_VERSION)" || { \
	  echo "::error::tag $(TAG) does not match v$(RELEASE_VERSION), the version in client/package.yaml"; \
	  exit 1; \
	}
	@echo "tag $(TAG) matches client/package.yaml $(VERSION)"

# ─── Docker ───────────────────────────────────────────────────
docker:
	docker build -f docker/Dockerfile -t krivostr:latest .

docker-down:
	docker compose -f docker/docker-compose.yml down

# ─── Clean ────────────────────────────────────────────────────
clean:
	stack clean
	rm -rf ui/dist ui/node_modules ui/coverage coverage.txt dist
