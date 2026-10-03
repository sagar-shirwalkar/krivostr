.PHONY: all build build-backend build-ui test test-backend test-ui \
        coverage coverage-backend coverage-ui docker docker-down clean

all: build

# ─── Build ────────────────────────────────────────────────────
build: build-backend build-ui

build-backend:
	stack build --fast

build-ui:
	cd ui && pnpm install --frozen-lockfile && pnpm build

# ─── Test ─────────────────────────────────────────────────────
test: test-backend test-ui

test-backend:
	stack test

test-ui:
	cd ui && pnpm test

# ─── Coverage ─────────────────────────────────────────────────
coverage: coverage-backend coverage-ui

coverage-backend:
	stack test --coverage
	hpc report --all > coverage.txt
	@echo "── Backend coverage written to coverage.txt (HPC enforces 80%)"

coverage-ui:
	cd ui && pnpm coverage

# ─── Docker ───────────────────────────────────────────────────
docker:
	docker build -f docker/Dockerfile -t krivostr:latest .

docker-down:
	docker compose -f docker/docker-compose.yml down

# ─── Clean ────────────────────────────────────────────────────
clean:
	stack clean
	rm -rf ui/dist ui/node_modules ui/coverage coverage.txt
