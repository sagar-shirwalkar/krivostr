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
| [`codeql.yml`][codeql] | SAST, TypeScript + workflows | PR, push to main, weekly | Yes |
| [`osv-scanner-pr.yml`][osvpr] | Dependency diff | PR | Yes, on new findings |
| [`osv-scanner-scheduled.yml`][osvsch] | Full dependency scan | push to main, weekly | No, reports only |
| [`scorecard.yml`][scorecard] | Repository posture | push to main, weekly | No, informational |
| Dependabot updates + alerts | Dependency notification | Weekly / continuous | No |

Dependabot **version updates** run weekly (Monday 05:30 UTC) for GitHub
Actions, Docker, and npm via [`.github/dependabot.yml`](../../.github/dependabot.yml)
— there is deliberately no Haskell entry, because Dependabot cannot read
`stack.yaml.lock`. Alerts notify continuously on known CVEs but do not open
PRs by themselves. The reasoning is in [`supply-chain.md`](supply-chain.md).

[codeql]: ../../.github/workflows/codeql.yml
[osvpr]: ../../.github/workflows/osv-scanner-pr.yml
[osvsch]: ../../.github/workflows/osv-scanner-scheduled.yml
[scorecard]: ../../.github/workflows/scorecard.yml

---

## CodeQL

**What it checks:** TypeScript and JavaScript source in `ui/` plus the
workflow files themselves (`javascript-typescript` and `actions` languages),
using the `security-extended` query pack. Catches injection sinks, insecure
randomness, path traversal, weak cryptography, and unsafe deserialisation.

**When it fires:** every pull request targeting `main`, every push to
`main`, and weekly (Wednesday 17:38 UTC).

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

## Dependabot updates and alerts

**What it does:** opens weekly version-update PRs for GitHub Actions,
Docker base images, and npm (`ui/`), and notifies via the Security tab and
email when any dependency has a known CVE.

**When it fires:** updates weekly (Monday 05:30 UTC); alerts continuously,
as GitHub's advisory database is updated.

**Coverage:** GitHub Actions, Docker, npm. Not Haskell — Dependabot cannot
read `stack.yaml.lock`. See the OSV
section above for what covers the Haskell tree.

**Tuning:** none on the alerts, but note the volume. If an alert arrives for a dependency
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
adversarial conditions. Nothing sends malformed Nostr events, malformed
WebSocket frames, or oversized payloads, and nothing observes the HTTP
surface the bridge actually serves.

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
none is redundant. Adding a sixth requires retiring one of the first five.
