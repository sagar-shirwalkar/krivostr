# Supply chain policy

How third-party code enters this repository, how it is pinned, and how
pinned code is updated. The policy exists because the alternative — trusting
mutable references — has been demonstrated to fail in public, repeatedly.

---

## The policy

**Every GitHub Action is pinned to a full-length commit SHA.** Not a tag,
not a major-version reference, not a branch. A forty-character hex string.

**Every pin carries a trailing comment with the version it corresponds to.**
The SHA is what git resolves; the comment is what a human reads.

```yaml
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
```

---

## Why

On 19 March 2026, an attacker published trivy v0.69.4 and force-pushed
76 of 77 version tags in aquasecurity/trivy-action, plus all seven
tags in aquasecurity/setup-trivy, to commits carrying a Python
infostealer. The malware harvested SSH keys, cloud credentials, Docker
configuration files, and cryptocurrency wallets from CI runners.

Any workflow referencing aquasecurity/trivy-action@v0.28 — or any other
tag — pulled the backdoored commit automatically on the next run. There was
no warning, no failed checksum, no signal that anything had changed. The
tag pointed at a different commit than it had the day before.

Pinning to a SHA does not prevent an attacker from publishing a malicious
commit. It prevents the attacker from retargeting an existing reference
at a malicious commit. A pinned workflow runs the exact code that was
reviewed, or it fails. That is the entire guarantee, and it is worth the
maintenance cost.

---

## Action Inventory

Every third-party action used in this repository, with its current pin and
the date it was last verified. Update the table when a pin changes; it is
the record of what "current" means.

---

## Finding a SHA

`git ls-remote` with the peeled ref is the shortest reliable method. The
`^{}` suffix dereferences an annotated tag to its commit, which is what a
workflow file needs. Without it, you get the tag object's SHA, which will
not work.

```bash
git ls-remote https://github.com/actions/checkout 'v4.1.1^{}'
```
The output is two fields: the SHA, then the ref. Take the first.

The equivalent with the GitHub CLI requires two calls for an annotated tag,
because the refs endpoint returns the tag object rather than the commit:

```bash
tagobj=$(gh api repos/actions/checkout/git/refs/tags/v4.1.1 --jq '.object.sha')
gh api "repos/actions/checkout/git/tags/${tagobj}" --jq '.object.sha'
```

To refresh the whole inventory at once:

```bash
#!/usr/bin/env bash
# Resolve a GitHub Actions version tag to the full-length commit SHA that
# `uses:` requires.
#
# Why `gh api` and not `git ls-remote`:
#
#   `git ls-remote --tags <url> refs/tags/<ref>` returns two lines for an
#   annotated tag (the tag object, then its peeled commit) and one line for
#   a lightweight tag. `tail -1` picks the right one in both cases, but the
#   correctness depends on an output ordering that git does not document as
#   a guarantee. A silent change there would hand you a tag-object SHA with
#   no error, and GitHub Actions will happily accept it — which is the worst
#   kind of wrong.
#
#   `gh api repos/<owner>/<repo>/commits/<ref>` dereferences annotated tags
#   server-side and always returns a commit. One code path, one failure mode.
#
# Requires `gh` to be authenticated. If it is not, the `git ls-remote` form
# is a fine fallback; see the note at the bottom.
set -euo pipefail

resolve() {
  local repo="$1" ref="$2" sha
  if ! sha=$(gh api "repos/${repo}/commits/${ref}" --jq '.sha' 2>/dev/null); then
    printf '%-40s %s\n' "$repo" "FAILED to resolve ${ref}" >&2
    return 1
  fi
  printf '%-40s %s  # %s\n' "$repo" "$sha" "$ref"
}

# Every third-party action used by this repository. Update this list when an
# action is added or a version is bumped; the output is what goes into the
# workflow files and into the inventory table in
# docs/security/supply-chain.md.
actions=(
  "actions/checkout                    v4.1.1"
  "actions/setup-node                  v4"
  "actions/cache                       v4"
  "actions/upload-artifact             v4"
  "actions/download-artifact           v4"
  "docker/setup-buildx-action          v3"
  "docker/build-push-action            v6"
  "github/codeql-action                v3"
  "google/osv-scanner-action           v2.3.1"
  "ossf/scorecard-action               v2.4.4"
  "zaproxy/action-baseline             v0.14.0"
  "gitleaks/gitleaks-action            v2"
)

failed=0
for entry in "${actions[@]}"; do
  # Split on the run of spaces between repo and ref.
  repo="${entry%% *}"
  ref="${entry##* }"
  resolve "$repo" "$ref" || failed=$((failed + 1))
done

if [ "$failed" -gt 0 ]; then
  echo >&2
  echo "${failed} action(s) failed to resolve" >&2
  exit 1
fi
```

---

## Updating pins

**A pin does not expire**. A workflow pinned to a SHA runs that SHA
forever, unless a GitHub-runner runtime change breaks it. The reason to
update is not that the pin stops working; it is that a newer commit exists
and might be better.

Three reasons to move a pin:
1. A security fix in the action itself. The reason the policy exists.
2. A feature the project needs. Rare for security tooling.
3. A Node.js runtime deprecation. GitHub periodically deprecates the 
Node version an action runs on. When it does, older actions stop
working and the pin has to move.

---

## Responding to a compromise

If an advisory names an action used in this repository:

1. **Read the advisory for the affected commit range**.  Force-pushed tags
affect every workflow that referenced the tag; a compromised release
affects only workflows that pinned to the compromised commit.
2. **If the pinned commit is in the affected range,** rotate every secret
the workflow could see. That means CLOUDFLARE_API_TOKEN, the GitHub
token, and anything in the repository secrets. Assume the runner was
compromised.
3. **Move the pin to a known-good commit,** verified independently — not a
tag the advisory says is safe, but a commit SHA you resolved yourself
after the advisory was published.
4. **Check the workflow run history** for the period between the
compromise and the fix. Failed authentication attempts, unusual network
egress, and unexpected workflow runs are the signals.
5. **Update the inventory table** with the new pin and a note in the
commit message referencing the advisory.

The Trivy incident is the reference case. Anyone maintaining a workflow
file should read at least one writeup of it, because the failure mode is
not exotic — it is a tag pointing at a different commit than it pointed at
yesterday, which is all a supply chain compromise needs to be.

---

## What is not pinned

1. **Docker base images.** `haskell:9.10.3-slim-bookworm` is a mutable tag.
Pinning it to a digest would be more correct and is a change worth making;
it is not currently done because the digest changes with every base image
security update and the pin would need to be refreshed constantly. The
tradeoff is explicit: base image drift is accepted, action drift is not.
2. **Haskell and npm dependencies.** These are resolved through
`stack.yaml.lock `and `pnpm-lock.yaml,` both of which are committed. The
lockfiles pin exact versions with cryptographic hashes, which is the
ecosystem's equivalent of a SHA pin. OSV Scanner audits both; see
[`scanning.md`](scanning.md).
3. **The Rust and Node toolchains** used by `ui/` and by the Docker build.
These are pinned by version in the workflow and the Dockerfile, which is
the standard practice and is not the same class of risk as an unpinned
action.

---

## `.github/SECURITY.md`

```markdown
# Security policy

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting][gh-pvr] for this repository.
It creates a private advisory visible only to you and the maintainer, and
keeps the discussion in one place.

If you cannot use GitHub's reporting flow, email
`security@example.invalid` with `krivostr` in the subject.

**Do not open a public issue for a security problem.**

[gh-pvr]: https://github.com/yourhandle/krivostr/security/advisories/new

## What to expect

- **Acknowledgement** within 7 days.
- **Initial assessment** within 30 days: whether the report is accepted,
  what the impact is, and a rough severity.
- **A fix or a decision not to fix** within 90 days for accepted reports.

This is a small project maintained in spare time. The timings above are
what can be met reliably, not what would be ideal. If a report is
time-sensitive — an actively exploited vulnerability, a live key
compromise — say so in the report and it will be handled first.

## What is in scope

The krivostr client, bridge, and core library:

- **Key handling.** The local signer's PBKDF2 + AES-GCM wrapping, the
  non-extractability of the derived `CryptoKey`, the failure modes of
  NIP-07 and NIP-46 signers.
- **Cryptographic implementation.** The Schnorr signing and verification
  in `core/`, the bech32 encoding in the UI, the canonical serialisation
  used for event IDs.
- **The bridge.** The SQLite store, the WebSocket endpoint, the HTTP
  static server, the binding defaults.
- **The UI.** XSS surface, the Content-Security-Policy, IndexedDB access
  patterns, the signer picker.
- **The build and release pipeline.** Workflow permissions, artifact
  integrity, the SHA pinning policy.

## What is not in scope

- **The Nostr protocol itself.** NIP-level issues belong in the
  [NIPs repository][nips].
- **Third-party relays.** Report problems with `relay.damus.io`,
  `nos.lol`, or any other relay to its operator.
- **Browser extension signers.** Alby, nos2x, and similar are separate
  projects. Report to them.
- **NIP-46 bunker services.** nsec.app and other bunkers are separate
  projects. Report to them.
- **Upstream dependencies.** Report to the maintainers of the affected
  package. Tell us as well so the pin can move, but the fix belongs
  upstream.
- **The hosted demo UI.** If you find a vulnerability in the Cloudflare
  Pages deployment that is not also present in the source, report it —
  but a general XSS on a static origin is not a finding against krivostr
  unless the CSP failed or the source is also affected.

## Please do not

- **Send a private key.** If a report involves `nsec`, `ncryptsec`, or
  any other key material, describe the vulnerability without including
  a real key. Generate a test key and share that if a reproduction is
  needed.
- **Test against relays or bunkers you do not control.** The scope above
  is the krivostr codebase, not the network it talks to.
- **Run automated scanners against any hosted instance** without prior
  arrangement. A local instance you started yourself is fine.

## No bug bounty

There is no financial reward for reports. Credit will be given in the
advisory and in release notes unless you ask not to be named.

## Disclosure

Fixes are published as a new release, with the advisory describing the
vulnerability and its impact. The advisory is published at the same time
as the fix, not before. If a fix requires coordination with a relay
operator, an extension maintainer, or another project, the timeline is
extended and the reporter is kept informed.

[nips]: https://github.com/nostr-protocol/nips
