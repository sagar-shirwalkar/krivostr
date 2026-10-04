# Automated security scanning

What runs, what it checks, when it fires, and how to tune it when it becomes
noisy. Every tool listed here is free for public repositories, and none of
them require a hosted service or an API key.

The design principle behind the whole set: **only surface findings that
someone would act on.** A scanner that fires on unpatchable CVEs or on
informational posture regressions trains reviewers to skim, and a skimmed
scanner is worse than no scanner.

---

## What is running

| Workflow | Category | Trigger | Fails the build? |
|---|---|---|---|
| [`codeql.yml`][codeql] | SAST, TypeScript | PR, push to main, weekly | Yes |
| [`osv-scanner-pr.yml`][osvpr] | Dependency diff | PR | Yes, on new findings |
| [`osv-scanner-scheduled.yml`][osvsch] | Full dependency scan | push to main, weekly | No, reports only |
| [`zap.yml`][zap] | HTTP surface, passive | PR touching `client/` or `docker/` | Configurable |
| [`scorecard.yml`][scorecard] | Repository posture | push to main, weekly | No, informational |
| Dependabot alerts | Dependency notification | Continuous | No |

Dependabot **version updates** are deliberately disabled. Only alerts are
enabled, which means GitHub notifies on a known CVE but does not open
update PRs. The reasoning is in [`supply-chain.md`](supply-chain.md).

[codeql]: ../../.github/workflows/codeql.yml
[osvpr]: ../../.github/workflows/osv-scanner-pr.yml
[osvsch]: ../../.github/workflows/osv-scanner-scheduled.yml
[zap]: ../../.github/workflows/zap.yml
[scorecard]: ../../.github/workflows/scorecard.yml

---

## CodeQL

**What it checks:** TypeScript and JavaScript source in `ui/`, using the
`security-extended` query pack. Catches injection sinks, insecure
randomness, path traversal, weak cryptography, and unsafe deserialisation.

**When it fires:** every pull request targeting `main`, every push to
`main`, and weekly (Monday 03:00 UTC).

**Why it is in the stack:** it is the only SAST tool in the set that reads
the source rather than the dependencies, and the UI is the component that
handles the private key. This is the scan to pay attention to.

**What it does not cover:** the Haskell core and the Haskell bridge. There
is no CodeQL extractor for Haskell and no realistic prospect of one. The
compensating control is the type system plus the review process, not a
scanner.

**Tuning:** the `security-extended` pack occasionally flags crypto code that
is correct. When it does, suppress the finding with an inline comment
explaining why, rather than disabling the query. The Security tab preserves
the suppressed finding, which is the audit trail.

---

## OSV Scanner

Two workflows, deliberately separate.

### `osv-scanner-pr.yml`

**What it checks:** the dependency diff between the PR branch and the base
branch. A vulnerability that already exists on `main` does not fail the PR;
only a vulnerability the PR introduces does.

**When it fires:** every pull request targeting `main`, plus `merge_group`
so it works with merge queues.

**Why it is in the stack:** Dependabot has no Haskell ecosystem. It cannot
read `stack.yaml.lock` at all. OSV Scanner reads both `stack.yaml.lock` and
`ui/pnpm-lock.yaml` natively, so it is the only tool in the repository that
audits the Haskell dependency tree.

### `osv-scanner-scheduled.yml`

**What it checks:** the full dependency tree, every lockfile, all known
vulnerabilities. Not a diff.

**When it fires:** push to `main`, weekly (Monday 04:30 UTC), and manually.

**Why it is separate:** a PR-only scan cannot catch a CVE published against
an unchanged dependency. The weekly run is what surfaces "the thing you
shipped last month is now known to be vulnerable."

**Tuning:** OSV Scanner reports by severity but does not fail the scheduled
run by design — a weekly report that turns the build red on a pre-existing
issue is a report people learn to ignore. Findings land in the Security
tab. Review them monthly.

---

## ZAP baseline

**What it checks:** the HTTP surface of the bridge. Passive only — it
observes the responses to requests it makes and flags missing security
headers, information disclosure, and misconfiguration. It does not attack.

**When it fires:** PRs that touch `client/` or `docker/`.

**Why it is in the stack:** it is the only check that looks at what the
bridge actually sends over HTTP. The Dockerfile's internal checks verify
the binary; ZAP verifies its behaviour.

**Tuning:** the baseline scan is configured with `fail_action: false` in
the workflow, so findings are reported but do not gate merges. This is
deliberate for a first pass. If the finding set stabilises at zero, flip it
to `true` and let it gate. If it stabilises at a small set of known
non-issues, add them to `.zap/rules.tsv` and then flip it.

**Known limitation:** ZAP does not understand WebSocket protocols. It
will scan `/` and the static assets, not `/ws`. Nostr's wire format is out
of scope for it, and no attempt is made to reach it.

---

## OSSF Scorecard

**What it checks:** repository posture, not code. Eighteen checks covering
branch protection, code review requirements, pinned dependencies, CI test
presence, security policy presence, token permissions, dangerous workflow
patterns, and others.

**When it fires:** push to `main`, weekly (Monday 05:15 UTC), and on branch
protection rule changes.

**Why it is in the stack:** the `Dangerous-Workflow` and `Token-Permissions`
checks audit the release pipeline's own configuration. Given that
`release.yml` carries `contents: write` and fires on tag push, a second
opinion on whether the workflow grants more than it needs is worth having.

**Tuning:** none. The score is informational. Do not gate anything on it.
Review the score quarterly and investigate regressions in individual checks
rather than the aggregate number.

**Interpreting the score:** 6/10 is normal for a personal repository with
one maintainer. Anything above 7 requires branch protection, required
reviews, and signed commits — good practices, but not obviously worth the
friction for a solo project. Treat the number as a directional signal, not
a target.

---

## Dependabot alerts

**What it does:** notifies via the Security tab and email when a dependency
has a known CVE. Does not open PRs.

**When it fires:** continuously, as GitHub's advisory database is updated.

**Coverage:** npm, Docker, GitHub Actions. Not Haskell. See the OSV
section above for what covers the Haskell tree.

**Tuning:** none, but note the volume. If an alert arrives for a dependency
that is not actually reachable in krivostr's code path, note that in the
alert's dismissal reason rather than dismissing silently. The dismissal
reasons are visible to anyone reading the Security tab and are the audit
trail.

---

## What is not covered

An honest gap analysis. These are the things that no workflow in this
repository checks:

**Haskell static analysis.** No SAST tool exists for Haskell that is
maintained, integrates with GitHub Actions, and produces findings worth
acting on. The type system catches whole classes of bugs that SAST tools
target in other languages, and the remaining risk is logic and resource
management, which no scanner reads well. The compensating controls are
`-Wall`, `-Werror` in CI, and review.

**Container image CVE scanning.** The Linux release pipeline builds
`docker/Dockerfile.linux`, but no workflow scans the resulting image for
CVEs in OS packages. The image is small and the OS package surface is
glibc, libgmp, and zlib, all of which are handled by the base image and by
Debian's security process. Adding Trivy is a one-file change if the gap
matters; it is currently judged not worth the runner cost.

**Runtime behaviour.** No workflow runs the client or the bridge under
adversarial conditions. ZAP observes the HTTP surface passively; nothing
sends malformed Nostr events, malformed WebSocket frames, or oversized
payloads.

**Cryptographic correctness.** No workflow verifies that the Schnorr
implementation is correct. It is covered by unit tests against known
vectors, not by a differential analysis.

**The hosted UI origin.** The Cloudflare Pages deployment is built by
`ui.yml` and deployed without any scanning beyond what runs on the PR that
touched it. If the deployment pipeline is ever compromised, no check in
this repository would notice.

---

## Adding a scanner

Three questions before adding one, in order:

1. **What does it cover that the existing set does not?** If the answer
   overlaps with an existing workflow, extend the existing one instead.
2. **Does it fail only on findings someone would fix?** A scanner whose
   first useful finding is three months out has already been ignored by
   then.
3. **Is it pinned to a full-length commit SHA?** No exceptions. See
   [`supply-chain.md`](supply-chain.md).

The set above is at the point where each tool covers a distinct surface and
none is redundant. Adding a seventh requires retiring one of the first six.
