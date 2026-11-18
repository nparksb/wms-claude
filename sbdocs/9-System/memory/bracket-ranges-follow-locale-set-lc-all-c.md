---
name: bracket-ranges-follow-locale-set-lc-all-c
description: "[A-Za-z] in bash =~ / grep follows the locale; glibc en_US.UTF-8 matches 'é', C/C.UTF-8/macOS do not — set LC_ALL=C in validating scripts"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 3f9a7b94-606c-402d-8bd7-6d7fd8a4920c
  modified: 2026-10-28T00:29:57.760Z
---

A bracket range such as `[A-Za-z0-9_]` in a bash `[[ $x =~ $re ]]` (and in grep/sed) is evaluated in the CURRENT locale. Under glibc `en_US.UTF-8` the range collates and matches `é`; under `C`, `C.UTF-8` and on macOS (BSD libc, any locale) it does not.

Measured 2026-10-28 on SBDEV-3132 PR #577: `check-migration-version-collision.sh` refused `V1.0.6__café.sql` on the Mac, in a Debian container (POSIX and C.UTF-8) and on Ubuntu 24.04 under C.UTF-8 — and ACCEPTED it on the GitHub runner, whose test JVM runs under an en_US-style locale. Reproduced with `docker run ubuntu:24.04` + `locale-gen en_US.UTF-8`.

**Why:** every local run was green, so the bug only surfaced on CI. A "works on Mac and Linux" check that does not vary the LOCALE misses it; owl's `portability-check.sh` has no rule for it (as of 2026-10-28).

**How to apply:**
- Any script that validates names/bytes with a bracket range: `LC_ALL=C; export LC_ALL` near the top (byte semantics for regex, glob and sort).
- Its self-test should run the non-ASCII case under `en_US.UTF-8` when `locale -a` lists it (SKIP otherwise) — the PR #577 harness case (k2) is the pattern.
- To reproduce a "green locally, red on CI" shell failure, vary the locale before suspecting bash version. Related: [[a-zero-scan-needs-a-positive-control]], [[grep-is-ugrep-skips-binary-without-dash-a]].
