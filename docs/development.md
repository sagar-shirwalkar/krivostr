# Development

Day-to-day workflow. Setup is in the [README](../README.md); this file covers
building, testing, and releasing.

The files this document used to quote in full — the Makefile, the workflows,
the Dockerfiles — are now linked rather than copied. A pasted copy of a file
that also exists in the repo is a copy that goes stale.

## Backend

```bash
stack build --fast     # build
 stack test             # 608 examples: 540 core, 68 client
stack ghci krivostr-core   # REPL against the pure layer
```

The resolver is `lts-24.61` (GHC 9.10.3) with no `extra-deps`. To change a
dependency, edit `stack.yaml` — never the `.cabal` files, which hpack
regenerates from `package.yaml`.

## UI

```bash
cd ui
pnpm install --frozen-lockfile
pnpm dev              # Vite dev server
pnpm typecheck        # tsc --noEmit
pnpm test             # 279 unit tests (jsdom)
pnpm test:browser     # 16 browser tests (real Chromium)
pnpm coverage         # v8, thresholds at 80
```

`pnpm test` alone skips the browser project. The browser tests drive real
WebSocket behaviour, so they are not optional — but they need Chromium
installed separately, because `pnpm install` fetches the Playwright driver and
not the browser:

```bash
pnpm exec playwright install chromium
```

On CI you also need `--with-deps`; `make test-ui` handles the local case.

Running `pnpm dev` needs `VITE_BRIDGE_URL` pointing at a running bridge, or
`?transport=bridge` on the URL — the Vite dev server does not proxy `/ws`.

## Make targets

| Target | Does |
|---|---|
| `make build` | Backend and UI. |
| `make test` | `test-backend` + `test-ui` (unit **and** browser). |
| `make coverage` | Backend report plus the UI v8 report. |
| `make linux-binary` | Release binary via Docker — needs Docker. |
| `make verify-version TAG=v0.4.3` | Fails if the tag disagrees with `client/package.yaml`. |
| `make docker` / `make docker-down` | Image build, compose teardown. |
| `make clean` | Build trees, `dist`, `ui/dist`, coverage output. |

See the [Makefile](../Makefile) for the exact recipes.

## Coverage

The two sides behave differently, and the difference is worth understanding.

**UI coverage is a working gate.** `pnpm coverage` enforces v8 thresholds of 80
across the board and passes.

**Backend coverage is a gate that currently fails.** `.hpc-threshold` requires
80%; the measured total is **55.7%** (546 of 980), so `make coverage-backend`
exits non-zero. That is intentional and unchanged — the threshold is the goal,
not the current state. The report is written to `coverage.txt` *before* the
gate runs, so a red run still leaves you numbers to read.

The NIP modules are well covered; the IO layers (Store,
Pool, Relay, Bridge, Cli) are not. CI does not run coverage at all, so this
gate is local-only for now.

Two notes on the tooling, both learned the hard way: `hpc report` cannot run
here at all (Stack leaves no `.mix` files, and `hpc 0.7` has no `--all` or
`--coverage` flags), so [`scripts/hpc-coverage.py`](../scripts/hpc-coverage.py)
parses the combined HTML index that `stack test --coverage` does write.

Do not lower `.hpc-threshold` to make the build green without discussing it.
Ratcheting it up as coverage improves is the point.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) has three jobs that
gate a merge:

| Job | Checks |
|---|---|
| `backend` | GHC 9.10.3 / lts-24.61, `stack test`, builds the release binary, smoke-tests it. |
| `ui` | Install, typecheck, build, unit tests, then Chromium install and browser tests. |
| `docker image` | Builds [`docker/Dockerfile`](../docker/Dockerfile) and serves the bundled UI from it. |

No coverage job. No Dockerfile linting.

## Releasing

krivostr ships **binaries, not a container image.** `docker build` appears in
the release workflow only as a way to produce a Linux binary on a known base —
nothing is pushed to a registry, and there is no `CHANGELOG.md` to update.

1. Bump `version` in [`client/package.yaml`](../client/package.yaml). It is the
   single source of truth: a Cabal version carries a fourth component, so
   `0.4.3.0` in the package file is released as the tag `v0.4.3`.
2. Check the tag before pushing it: `make verify-version TAG=v0.4.3`.
3. Tag and push. The tag is what triggers the release.

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on a
`v*` tag push or by hand with an existing tag, re-checks the version against
`client/package.yaml`, and uploads tarballs for Linux (built in
[`docker/Dockerfile.linux`](../docker/Dockerfile.linux)), macOS, and Windows.

**The UI deploys separately.** [`.github/workflows/ui.yml`](../.github/workflows/ui.yml)
publishes `ui/dist` to Cloudflare Pages on every push to `main`. The Pages
deployment needs `VITE_BRIDGE_URL` set in the Pages environment, or the built
UI has no bridge to talk to.

## Docker

[`docker/Dockerfile`](../docker/Dockerfile) is a three-stage build (Haskell
builder, Node builder, Debian runtime) producing an image that serves the UI
and the bridge on port 8081 with `/data` as a volume.
[`docker/Dockerfile.linux`](../docker/Dockerfile.linux) builds the release
binary and enforces the glibc floor.

Validate Docker and release changes **through CI**. Do not run Docker locally
in this repo; `make linux-binary` in particular produces a release artifact and
belongs on a release runner.
