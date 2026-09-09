# Orphaned tests — written, never committed, still relevant

Working tests found untracked in a checkout, whose subject shipped without them. Copied here because
an untracked file in a working checkout is one `git clean -fd` from gone, and these guard live code.

**This is a holding area, not a home.** Each file belongs on a ticket; the ticket owns landing it.

| file | guards | found | assigned to |
|---|---|---|---|
| _(empty)_ | | | |

---

## ⚠️ Intake rule, learned the hard way 2026-09-01 — key on CONTENT, never on PATH

The first and only file this area ever held, `reprintLabelHostSet.spec.js`, was **not orphaned**. It was a
version that had been committed and then **deliberately withdrawn fifteen minutes later**, by
`v2/wms2-web-ui` commit `d29348c`, whose subject line is *"review F1-F7 — the pin missed the hazard it
exists for"*. That commit deleted it and replaced it with a **stronger** successor at a different path,
`test/util/reprentLabelHostSet.spec.js`, which has been on `origin/develop` ever since.

**Why the intake check missed that.** It searched every remote ref for the **path**
`test/components/handlingUnits/popups/reprintLabelHostSet.spec.js`. The successor sits at a different path
under a different spelling (`reprent`, not `reprint`, carried over from the real filename typo). **A path
sweep cannot see a rename.** The check then reported "committed on no branch", which was literally true of
that path and completely wrong about the world.

It is worth noting exactly how convincing the false conclusion looked. The intake verified — correctly —
that the file passes, that it is mutation-checked with an attributable kill, and that its subject is live on
`origin/develop`. Three true findings, and the one unverified premise ("its only UI-side guard did not
ship") was the one that mattered. The resurrected version was then measurably **weaker** than the one
already shipped: it missed the no-import auto-registration mutant entirely, mis-stated the ANY-of
arithmetic as one member per screen, left `WEB_UI_VIEW_STOCK_UNIT` unfenced, and re-asserted a member
distinctness check that had been removed for going red on a correct config.

**So, before adding anything here:**

1. `git log --all --follow -- <path>` — follows renames, which a ref sweep does not.
2. Search the repo for the test's **invariant**, not its filename: the symbol, endpoint or component it
   pins. Here, `grep -rl reprentLabel test/` on `origin/develop` would have found the successor instantly.
3. Check whether a commit **deleted** it, and read that commit's message. A deletion fifteen minutes after
   an addition is a withdrawal, not an accident, and the message usually says why.
4. Only then is it an orphan.

Corollary for the general case: **a file being absent from the path you remember is not evidence that its
guarantee is absent.** Verify the guarantee, not the file.
