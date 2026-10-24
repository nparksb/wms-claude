---
name: owl-tooling-scripts-break-on-macos-bsd-userland
description: "Nam uses BOTH macOS (bash 3.2, BSD tools) and Linux; run .claude/scripts/portability-check.sh after editing any script"
metadata:
  node_type: memory
  type: project
  originSessionId: d97d7075-356d-49e4-9eb2-32dbd1172288
  modified: 2026-10-24T13:12:17.548Z
---

Nam works on two machines: macOS (`/bin/bash` 3.2, BSD grep/date/stat/sed/find/awk) and a Linux box (bash 5, GNU). The owl `.claude` and `sbdocs/9-System/scripts` shell scripts were first written on Linux, and on 2026-10-23/24 many of them failed on the Mac. Two failed OPEN:
- `! grep -qvP` made post-merge-verify read "all CI runs completed";
- `grep -z` means "decompress" on BSD, so a multi-line verify row silently stopped matching.

Fixed in owl commits `074c81f` through `768abe3`. 768abe3 adds `.claude/scripts/portability-check.sh`, which ran ALL PASS on the Mac and in a Debian bash-5/GNU container.

**Why:** a GNU-ism on the Mac rarely errors loudly. It returns empty, or exit 2 that a `!` flips, and that reads as a pass. A broken scanner returns a clean zero; this checker's own first version did exactly that (BSD awk rejects a newline in `-v`), and its positive control caught it.

**How to apply:**
- After editing any shell script, run `/bin/bash .claude/scripts/portability-check.sh` on the current machine.
- Use the dual-path helpers (`epoch_of`, `mode_of`, `main_root`). Never hardcode `/home/nampark` or `/Users/np1076`.
- Prove a script change with old vs new on GNU (Docker `debian:bookworm-slim`) plus new on the Mac.
- Harness traps that bit me three times: a copied script derives its root from where the COPY sits, so pass roots explicitly. `timeout` does not exist on macOS. Your interactive `grep` is a ugrep function that supports -P, so test with `env grep`.

**Open follow-ups (Nam chose to stop the review loop here, 2026-10-24; review report: the session scratchpad rereview-fb0f309.md):**
- F1: verify-260504 rows A1/B1/C2 pass with the fix deleted (their `.*` matches anywhere in the file); scope them to method bodies. v1 script, low value.
- Lows: an unclosed `portability-check: off` silences the rest of a file; a NEW copy of a helper is exempt and never compared; false positives possible on `xargs rm -rf` / `go test -v`; JAVA_TOOL_OPTIONS breaks plan-state's JDK version check; 0-byte files pass negative checks; fences spelled `shell`/`~~~` are not scanned; U14's -E exemption is line-wide; stale helper comments in 2732/2854; 2967-C T6 passes when its test file is missing.

Related: [[grep-is-ugrep-skips-binary-without-dash-a]], [[a-zero-scan-needs-a-positive-control]].
