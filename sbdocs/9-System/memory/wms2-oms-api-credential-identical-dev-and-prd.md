---
name: wms2-oms-api-credential-identical-dev-and-prd
description: "SBDEV-3181 — OMS_API_USER is byte-identical on ALL SIX v2 tenant DBs including Hydra PRD, so the dev value IS the production credential; rides HTTP Basic on every outbound OMS call, one of which targets a sysprop-chosen URL"
metadata:
  node_type: memory
  type: project
---

**Measured 2026-09-01 (SBDEV-3154 security lane, confirmed): the `OMS_API_USER` sysprop is
byte-identical on `dev_wh01_om1` and `wh01_hydra_v2` (Hydra PRD).** So the dev value *is* the
production OMS credential — anyone with dev DB or dev sysprop access holds prd's. Do **not** copy the
value into any document; re-derive it from the environment. (A review lane pasted it into
`sbdocs/1-Projects/wms2/plan/SBDEV-3154-evidence/impl-security.md`; redacted same day.)

`HttpRestService.applyHeaders` attaches it as HTTP **Basic** auth to every outbound OMS call. That
matters most for `AdminActionController.testCrmConnectivity`, whose target URL is read from the
`WEBSERVICE_TEST_CRM_CONNECTIVITY` sysprop **at call time** — and `Sysprop` is deliberately excluded
from the SDR write withdrawal (`RestConfiguration:306-310`, one of the eleven types kept writable for
a UI writer). So a rewritten URL exfiltrates the prd-equivalent credential. Configured-open, **not**
measured exploitable — and a 400 from an SDR write verb proves nothing either way
([[sdr-write-verb-probes-400-proves-nothing]]).

SBDEV-3154 (PR #259) gates that endpoint, which narrows *who can trigger the call* on dev from 100
users to 37. It does **not** touch the shared credential, and must not be described as doing so.

**Status: FILED as SBDEV-3181, 2026-09-01, High**, on Nam's explicit instruction after being raised as
a proposal (T3 findings are proposed first, never filed unilaterally). Cross-linked both ways with
[[wms2-landlord-db-password-committed-live]] (SBDEV-3175) — same class, *"one secret with no
environment boundary"*, and both need a second system coordinated during rotation (landlord DB
consumers there, OMS here). Related: [[sbdev-3154-admin-action-console-gating]].

**The full sweep, and the control that makes it a finding.** All **six** v2 tenant DBs carry
`md5 = bca59d207ef3097fcfd44dbda5efe8a6`, length 19, username half `api_user`: `dev_wh01_om1`,
`wh01_om1_v2`, `wh01_hydra_v2` (**PRD**), `wh01_hydra_v2` (UAT — same DB *name*, different server),
`wh01_shipitez_v2`, `wh02_shipitez_v2`. ⚠ **Compare hashes, never read the value.** The control:
`OMS_TENANT_ID` and `WEBSERVICE_TEST_CRM_CONNECTIVITY` in the *same table* DO differ per environment
(`wineco`/`hydra`, different URL lengths) — so this is not a cloned table, only the credential lacks
an environment boundary.

**What is NOT established** (recorded so nobody upgrades the claim): not measured exploitable — no
`PATCH /v3/sysprop/{id}` was attempted, and a 400 there proves nothing either way; whether one shared
service account is *intentional* is unknown and is AC-1 on the ticket; the sweep covered six WMS DBs
only, **not** OMS-side config, CI secret stores or `.env`.
