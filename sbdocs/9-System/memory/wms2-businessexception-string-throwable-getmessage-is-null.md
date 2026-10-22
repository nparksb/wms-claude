---
name: wms2-businessexception-string-throwable-getmessage-is-null
description: "v2 BusinessException.getMessage() resolves from a key — the no-arg and (String, Throwable) constructors yield null, not the message"
metadata:
  node_type: memory
  type: project
  originSessionId: a929abe8-f111-4992-8a63-d5b644afd391
  modified: 2026-10-11T22:26:34.378Z
---

In v2/wms2-api, `BusinessException.getMessage()` is overridden to `resolveMessage(null, key, parameter)`. The `(String message, Throwable cause)` and no-arg constructors set no key, so `getMessage()` returns null even though a message was passed. `new BusinessException((String) null)` goes through the placeholder key and yields the literal "null". `FacadeException.getMessage()` falls back to `key + ", " + …` when the message is empty.

**Why:** found in SBDEV-3728 review round 2. A comment claimed the opposite, and code that forwards `cause.getMessage()` to OMS (the finishedTransfer 400 description) silently falls back to generic text for those constructors.

**How to apply:** when forwarding an exception's reason anywhere (to OMS, a FAILED message row, a log), do not assume `getMessage()` holds the constructor's message for a BusinessException. Check which constructor the throw site uses. Related: [[wms2-businessexception-key-vs-message-traps]].
