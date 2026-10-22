---
name: hub-flyway
description: Flyway behaviour and traps in wms2 (runtime migrate, version picks, ownership, SQLSTATE). Hub: one line per member memory
metadata:
  type: reference
---

Hub for **Flyway runtime, versioning, ownership and error traps**. Moved out of MEMORY.md on 2026-10-15 to keep the index under its size limit; each line links the member memory.

- [[sbdev-2801-runtime-flyway-default-on]]: SBDEV-2801: runs every boot, every env
- [[flyway-runbook-covers-dev-and-uat-via-env-flag]]: tenant runbook (--env required)
- [[flyway-version-pick-sweep-all-remote-branches]]: pick versions: sweep ALL branches
- [[flyway-collision-sweep-cannot-catch-a-branch-pushed-later]]: sweep misses later branches
- [[los-sysprop-description-varchar-255-aborts-migration]]: sysprop.description varchar(255)
- [[wms2-tenant-object-ownership-blocks-flyway]]: ownership drift blocks it
- [[wms2-flyway-migration-facts-corrected]]: 3 false header claims
- [[flyway-error-message-contains-the-script-filename]]: errors quote filename: assert SQLSTATE
