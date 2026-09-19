---
name: run-v1-wms-web-ui-jest-tests
description: How to run v1/wms-web-ui Jest tests when yarn is not on PATH
metadata: 
  node_type: memory
  type: reference
  originSessionId: 3889da24-2941-49de-ad73-50f36d7f30a1
---

`yarn` is NOT on PATH in this environment. To run v1/wms-web-ui (Nuxt 2) Jest tests, use the local jest binary with nvm node:

```bash
cd v1/wms-web-ui
export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"   # node v24.15.0
node_modules/.bin/jest --testPathPattern="<pattern>"
```

Jest config + the `node_modules/.bin/jest` binary are present. Test files live under `test/` (e.g. `test/store/...`, `test/components/...`). Mirrors the Java side where mvn/java need SDKMAN PATH — see [[run-v1-wms-api-testcontainers-its-locally]].
