---
name: wms2-rts-roadmap-decisions
description: "Nam's five settled design decisions for the v2 Return to Stock roadmap (SBDEV-3313) — returns route, putaway feed, rapid-picking guard, reverse-picking scope, source-bin vs putaway destination"
metadata: 
  node_type: memory
  type: project
  originSessionId: cafcc809-95cd-4f7f-ad6f-7439a6660c6e
  modified: 2026-09-11T01:25:17.130Z
---

**Nam, 2026-09-10 — five RTS roadmap decisions, settled on SBDEV-3313. Do not re-litigate.**

- **D1 — returns get back to stock via the inbound-BOL rapid receive (SBDEV-2778), NOT via RTS.**
  RTS stays **cancellation-only**. Keep only the *ergonomics* of the scan-an-empty-tote idea as a
  mobile front-end onto 2778's receive — never a second backend. Rename the "Return to Stock (RTS)"
  menu rather than reshape the backend to fit the label. Driver: 2778 is already half-built
  (`ReturnAdviceAutoReceiveService` ships ON) and WineCo UAT holds 2,796 `RETURN` advices.
- **D2 — feed putaway from a non-receipt source with a SYNTHETIC ADVICE** (new `AdviceType`,
  auto-closed at creation like `ReturnAdviceAutoReceiveService`). **Do NOT loosen
  `Goodsreceiptposition.advicepositionId`** — that FK is what makes all putaway work traceable to an
  Advice, and nulling it would turn every receipt→advice query conditional for every consumer.
- **D3 — just fix the `RAPID_PICKING` / `markedforcancellation` branch**; it was never really a
  decision. No live RAPID_PICKING anywhere: 0 sections on Hydra PRD and both ShipItEZ UATs, and
  WineCo's only one is `test_section`, unused since 2022-03-13.
- **D4 — "reverse picking" means pick-path-ordered multi-stop putaway FIRST** (reuse
  `calculatePutAwayList`'s pick-path sort + the 4-tier `PutawayDestinationResolver`). Full
  interleaved multi-tote routing only if measured walking time justifies it.
- **D5 — cancelled stock goes back to its SOURCE BIN for a single-tote RTS, but to the PUTAWAY
  QUEUE once the tote joins a Cart.** Cart membership is the switch. Third rule: when the source bin
  is unavailable (full, or flowbin reassigned to another SKU — today an HTTP 409 from
  `transferStock`), **fall through to putaway rather than blocking the operator**. This answers
  SBDEV-1921's never-reviewed follow-up **F3** (source-location fallback): warranted, and putaway
  beats a staging location because it already has destination resolution and an operator workflow.

**How to apply:** the first increment of any cart work is to **actually mint a `Cart` unit load and
hang totes off `carrierunitload_id`** (the palletizing `transferUnitLoadToCarrier` mechanism pointed
at Cart). The `Cart` type is seeded everywhere but has **0 instances** on Hydra PRD and WineCo UAT,
and `PickingOrderMergeService` tracks `PICKING_BOX_PER_CART` as a plain counter without ever
creating one — the two halves of "cart" are disconnected today.

**The structural reason RTS and returns cannot merge at intake** (and D5's basis): a cancellation is
a **move** — stock is already in WMS, quantity-neutral, destination is the remembered
`pickfromlocationname`. A return is a **receipt** — stock is outside WMS, quantity-additive, and has
no source bin so its destination must be *resolved*. They converge only at the **putaway** layer,
which is precisely what D2's synthetic Advice produces: both become an Advice feeding one putaway
queue, which is what lets one cart carry mixed cancelled and return totes.

Blockers for the roadmap are [[wms2-rts-completereversal-moves-no-stock]] (SBDEV-3316) and
SBDEV-3264. R3 (damaged at receipt) belongs to SBDEV-1512, not to 3313. Related:
[[wms2-authz-axis-keycloak-coarse-functions-fine]], [[consolidate-tickets-dont-file-one-per-finding]].
