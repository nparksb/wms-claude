---
name: hub-it-shared-state-crosstalk
description: Integration-test state leaking across tests (shared H2, reused containers, sequences, concurrent Maven). Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Shared IT DB/container cross-talk**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[wms2-baserollback-shared-h2-create-drop]]: BaseRollbackIT shared one H2 DB — FIXED both lanes (SBDEV-1581, SBDEV-3843)
- [[new-test-context-fork-breaks-an-unrelated-it]]: Context-forking IT breaks another
- [[reused-container-accumulates-sequences-not-just-rows]]: Reused container keeps SEQUENCES
- [[concurrent-maven-one-worktree-false-reds]]: Concurrent Maven (or jdtls) = false reds
