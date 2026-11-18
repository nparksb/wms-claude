---
name: wms2-ingress-traefik-readtimeout-60s-not-a-response-bound
description: "wms2-api dev/UAT/prd ingress is Traefik; its 60 s readTimeout bounds request READING only, not slow responses — don't cite it as a margin"
metadata:
  node_type: memory
  type: reference
  originSessionId: dd3081da-4cfe-4121-a3f3-ae66fc71e41c
  modified: 2026-11-09T15:28:00.050Z
---

Measured 2026-11-10 (SBDEV-4045): wms-api.dev.sbo.li, wms-api.uat.sbo.li and wms-api.sbo.li are all **Traefik** directly (no CDN).
Entrypoint `readTimeout` = **60 s** on all three. A partial header that stalls is dropped at 60.1 s. A header that trickles in one line every 20 s is dropped at 60.2 s. So this is an absolute deadline, not an idle timeout.

**Trap:** that 60 s does NOT cut a slow response to a bodiless request. Go clears the read deadline once the request has been read. On a local traefik v3.3.7 with default config, 70 s GETs returned 200 over h1 and h2. With `responseHeaderTimeout: 20s` set as a control, the same setup returned 504 at 20 s. Only a response-side setting (`serversTransport` forwardingTimeouts or a middleware) bounds a long GET, and Traefik's default is none.
- Dev response bound observed: **≥ 57.8 s** (a browser `runClubLine` call, SBDEV-3310).
- UAT/prd response bound: unknown until DevOps exports the stack config (Q-INFRA-1).

**How to apply:** when sizing a long-held request such as `app.clubline.sync-wait-seconds`, use the response-side bound, not "the 60 s read timeout". The stall and trickle probes are safe to run even on prd, because they never reach wms2-api. Scripts: `stall.py` and `trickle.py` (in the SBDEV-4045 ticket comment).
