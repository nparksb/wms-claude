# CUPS Dependency Removal Plan

## Summary

Replace the custom `library/cups4j-0.6.4.jar` with the standard `org.cups4j:cups4j:0.7.9` from Maven Central. This eliminates the need to bundle a local JAR, simplifies Dockerfiles, and uses a maintained version of the library.

## Current State

### Custom JAR: `library/cups4j-0.6.4.jar`

- **Package**: `org.cups4j` (same as the standard library)
- **Bundled dependencies**: Includes `org.simpleframework.xml` and `ch.ethz.vppserver` IPP classes inside the JAR
- **Installation**: Manually installed to local Maven repo during Docker build via `mvn install:install-file`
- **pom.xml coordinates**: `groupId=cups4j`, `artifactId=cups4j`, `version=0.6.4` (non-standard groupId)

### CUPS4J Classes Used (only in `PrintService.java`)

| Class | Usage |
|-------|-------|
| `org.cups4j.CupsClient` | `new CupsClient(ip, port)` — connect to CUPS server |
| `org.cups4j.CupsPrinter` | `cupsClient.getPrinter(url)` — get printer by URL |
| `org.cups4j.PrintJob` | `new PrintJob.Builder(bytes).attributes(map).build()` — create print job |
| `org.cups4j.PrintRequestResult` | `cupsPrinter.print(printJob)` — read jobId, resultCode, resultDescription, isSuccessfulResult |

### Call Sites (5 services, 8 total calls)

| File | Method(s) Called | Business Purpose |
|------|-----------------|------------------|
| `PrintService.java` | Direct cups4j usage | Core printing integration (only file with cups4j imports) |
| `StockunitService.java` | `cupsPrint()` x2 | Inbound case label printing |
| `UnitloadService.java` | `cupsPrint()` x1 | Tote/pallet label printing |
| `OrderMonitorViewService.java` | `cupsPrint()` x2 | Picking tote label printing |
| `ReceivingService.java` | `isPrintAvailable()` + `cupsPrint()` | Receiving case label printing |
| `PrinterController.java` | `testPrint()` + `cupsPrint()` | REST API for printer management |

### Dockerfiles Affected

| File | Lines | What They Do |
|------|-------|--------------|
| `Dockerfile` | 6-8 | `ARG LIB_FILE=cups4j-0.6.4`, COPY jar, `mvn install:install-file` |
| `Dockerfile_new` | 6-8 | Identical to Dockerfile |
| `Dockerfile_old` | N/A | No cups4j installation (legacy, pre-dates the dependency) |

---

## Compatibility Analysis

### Can the custom JAR be replaced by the standard library?

**Yes.** The replacement is straightforward because:

1. **Same package**: Both use `org.cups4j.*` — no import changes needed
2. **API compatibility**: All 4 classes used (`CupsClient`, `CupsPrinter`, `PrintJob`, `PrintRequestResult`) exist in 0.7.9 with the same method signatures used by the project:
   - `new CupsClient(String host, int port)` — present in both versions
   - `cupsClient.getPrinter(URL)` — present in both versions
   - `new PrintJob.Builder(byte[]).attributes(Map).build()` — present in both versions
   - `cupsPrinter.print(PrintJob)` — present in both versions
   - `PrintRequestResult.getJobId()`, `.getResultCode()`, `.getResultDescription()`, `.isSuccessfulResult()` — present in both versions
3. **No direct construction of `CupsPrinter`**: The project only gets `CupsPrinter` via `cupsClient.getPrinter()`, so the constructor signature change between versions is irrelevant
4. **No custom modifications detected**: The JAR's `org.cups4j` classes match the upstream structure (same class names, same operations package)

### Potential Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Bundled `simpleframework-xml` conflicts with other dependencies | Low | Standard 0.7.9 also bundles it; verify no classpath conflicts |
| Behavioral differences in IPP protocol handling | Low | Same protocol, same server; test with actual CUPS server |
| `DEFAULT_USER` changed from `"anonymous"` to `System.getProperty("user.name")` | None | Project never uses default user — always creates `CupsClient(ip, port)` without username |

---

## Implementation Plan

### Step 1: Update `pom.xml`

**File**: `pom.xml` (lines 345-349)

Replace:
```xml
<dependency>
    <groupId>cups4j</groupId>
    <artifactId>cups4j</artifactId>
    <version>0.6.4</version>
</dependency>
```

With:
```xml
<dependency>
    <groupId>org.cups4j</groupId>
    <artifactId>cups4j</artifactId>
    <version>0.7.9</version>
</dependency>
```

**Note**: The groupId changes from `cups4j` to `org.cups4j` (the official Maven Central coordinate).

### Step 2: Update `Dockerfile`

**File**: `Dockerfile`

Remove lines 6-8:
```dockerfile
ARG LIB_FILE=cups4j-0.6.4
COPY library/${LIB_FILE}.jar /app/libs/
RUN mvn install:install-file -Dfile=/app/libs/${LIB_FILE}.jar -DgroupId=cups4j -DartifactId=cups4j -Dversion=0.6.4 -Dpackaging=jar
```

The dependency will now be resolved automatically from Maven Central during `mvn clean package`.

### Step 3: Update `Dockerfile_new`

**File**: `Dockerfile_new`

Same change as Step 2 — remove lines 6-8.

### Step 4: Update `Dockerfile_old`

**File**: `Dockerfile_old`

No changes needed — this file never had the cups4j installation.

### Step 5: Delete the local JAR

Delete `library/cups4j-0.6.4.jar` from the repository.

**Important**: If the `library/` directory becomes empty after this, delete the directory as well.

### Step 6: No Java Code Changes Required

`PrintService.java` imports `org.cups4j.*` which is the same package in both versions. All method signatures used are compatible. **Zero Java changes needed.**

### Step 7: Verify Build

```bash
mvn clean package -DskipTests -Dmaven.javadoc.skip=true
```

### Step 8: Test Printing (Manual)

Since printing requires a live CUPS server, this must be tested manually:
1. Deploy to a test environment with CUPS server access
2. Verify `PrinterController.testPrint()` works
3. Verify inbound case label printing (via `StockunitService`)
4. Verify picking tote label printing (via `OrderMonitorViewService`)

---

## Changes Summary

| File | Change | Lines Affected |
|------|--------|----------------|
| `pom.xml` | Update groupId from `cups4j` to `org.cups4j`, version from `0.6.4` to `0.7.9` | 345-349 |
| `Dockerfile` | Remove 3 lines (ARG, COPY, RUN install-file) | 6-8 |
| `Dockerfile_new` | Remove 3 lines (ARG, COPY, RUN install-file) | 6-8 |
| `Dockerfile_old` | No change | — |
| `library/cups4j-0.6.4.jar` | Delete file | — |
| Java source files | **No changes** | — |

**Total**: 2 files modified, 1 file deleted, 6 lines removed, 0 Java code changes.

---

## Execution Status

| Step | Description | Status | Date |
|------|-------------|--------|------|
| 1 | Update `pom.xml` — groupId `cups4j` → `org.cups4j`, version `0.6.4` → `0.7.9` | DONE | 2026-02-22 |
| 2 | Update `Dockerfile` — removed 3 lines (ARG, COPY, install-file) | DONE | 2026-02-22 |
| 3 | Update `Dockerfile_new` — removed 3 lines (ARG, COPY, install-file) | DONE | 2026-02-22 |
| 4 | `Dockerfile_old` — no changes needed | N/A | — |
| 5 | Delete `library/cups4j-0.6.4.jar` and empty `library/` directory | DONE | 2026-02-22 |
| 6 | Java code changes — none required | N/A | — |
| 7 | Verify build — `mvn clean package -DskipTests` — **BUILD SUCCESS** | DONE | 2026-02-22 |
| 8 | Manual printing test on environment with CUPS server access | PENDING | — |
