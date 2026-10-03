.PHONY: all build build-backend build-ui static test test-backend test-ui \
        test-ui-browser coverage coverage-backend coverage-ui docker docker-down \
        verify-version clean

VERSION := $(shell sed -n 's/^version:[[:space:]]*//p' client/package.yaml | head -1)
# A Cabal version carries a fourth component that a release tag has no use for:
# 0.2.0.0 is packaged, v0.2.0 is the tag.
RELEASE_VERSION := $(word 1,$(subst ., ,$(VERSION))).$(word 2,$(subst ., ,$(VERSION))).$(word 3,$(subst ., ,$(VERSION)))

all: build

# ─── Build ────────────────────────────────────────────────────
build: build-backend build-ui

build-backend:
	stack build --fast

build-ui:
	cd ui && pnpm install --frozen-lockfile && pnpm build

# One statically linked Linux executable, built and checked inside Docker so the
# result is the same on a laptop and on a release runner.
static:
	docker build -f docker/Dockerfile.static --target build -t krivostr:static .
	mkdir -p dist
	cid=$$(docker create krivostr:static); \
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
test-ui:
	cd ui && pnpm install --frozen-lockfile && pnpm test && pnpm test:browser

test-ui-browser:
	cd ui && pnpm test:browser

# ─── Coverage ─────────────────────────────────────────────────
coverage: coverage-backend coverage-ui

coverage-backend:
	stack test --coverage
	./scripts/check-coverage.sh
	hpc report --all > coverage.txt
	@echo "── Backend coverage written to coverage.txt"

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
