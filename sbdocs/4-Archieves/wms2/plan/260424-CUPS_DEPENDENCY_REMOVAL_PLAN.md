# CUPS Custom Library Removal Plan

## Summary

Replace the custom bundled `library/cups4j-0.6.4.jar` with the standard Maven Central artifact `org.cups4j:cups4j:0.7.9`. This is a **drop-in replacement** — no Java code changes are required.

---

## Current State

### Custom Library

- **File:** `library/cups4j-0.6.4.jar` (2.1 MB, committed to git)
- **Origin:** Forked/customized version of cups4j 0.6.4
- **Installation:** Manually installed into the local Maven repo during Docker builds via `mvn install:install-file`

### pom.xml Dependency (lines 215–237)

```xml
<dependency>
    <groupId>cups4j</groupId>
    <artifactId>cups4j</artifactId>
    <version>0.6.4</version>
    <exclusions>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-api</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-nop</artifactId></exclusion>
        <exclusion><groupId>ch.qos.logback</groupId><artifactId>logback-classic</artifactId></exclusion>
    </exclusions>
</dependency>
```

### Dockerfiles Affected

Both `Dockerfile` and `Dockerfile_new` (lines 6–8) install the custom jar:

```dockerfile
ARG LIB_FILE=cups4j-0.6.4
COPY library/${LIB_FILE}.jar /app/libs/
RUN mvn install:install-file -Dfile=/app/libs/${LIB_FILE}.jar -DgroupId=cups4j -DartifactId=cups4j -Dversion=0.6.4 -Dpackaging=jar
```

`Dockerfile_old` has no CUPS-related lines (it expects a pre-built jar).

---

## CUPS Usage in the Codebase

### Single Integration Point

**Only one file imports cups4j classes:** `PrintService.java`

```
src/main/java/net/aim_ai/wms/service/PrintService.java
```

Imports used:
- `org.cups4j.CupsClient` — connect to CUPS server
- `org.cups4j.CupsPrinter` — get printer by URL
- `org.cups4j.PrintJob` — build print job with ZPL content
- `org.cups4j.PrintRequestResult` — check print result

### Methods Using cups4j

| Method | Lines | Purpose |
|--------|-------|---------|
| `cupsPrint(String, byte[])` | 89–127 | Submit ZPL label data to a CUPS printer via IPP |
| `isPrintAvailable(String)` | 129–159 | Check if a CUPS printer is reachable |
| `testPrint(String)` | 75–87 | Send test ZPL to a printer (calls `cupsPrint`) |

### Callers (8 call sites across 5 services + 1 controller)

| File | Method | Call | Purpose |
|------|--------|------|---------|
| `ReceivingService.java:302` | `receiveGoods()` | `isPrintAvailable()` | Check printer before receiving |
| `ReceivingService.java:543` | `receiveGoods()` | `cupsPrint()` | Print inbound case label |
| `StockunitService.java:256` | `createStockUnit()` | `cupsPrint()` | Print case label on SU creation |
| `StockunitService.java:489` | `printCaseLabel()` | `cupsPrint()` | Print case label on demand |
| `UnitloadService.java:224` | `createUnitload()` | `cupsPrint()` | Print tote/pallet label |
| `OrderMonitorViewService.java:198` | `printPickingToteLabel()` | `cupsPrint()` | Print picking tote label |
| `OrderMonitorViewService.java:343` | `printPickingToteLabelAutomation()` | `cupsPrint()` | Print automation tote label |
| `PrinterController.java:241` | `testPrinter()` | `cupsPrint()` | Test print from REST endpoint |

### Configuration (database system properties)

| Constant (WmsConstants) | DB Key | Example Value |
|--------------------------|--------|---------------|
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_IP_KEY` | `CUPS_SERVER_ADDRESS_IP` | `oms-dev.siteboss.net` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_PORT_KEY` | `CUPS_SERVER_ADDRESS_PORT` | `631` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_USERNAME_KEY` | `CUPS_SERVER_ADDRESS_USERNAME` | `aimprint` |
| `SYSTEM_PROPERTY_CUPS_SERVER_ADDRESS_PASSWORD_KEY` | `CUPS_SERVER_ADDRESS_PASSWORD` | *(encrypted)* |
| `SYSTEM_PROPERTY_PRINT_CASE_LABEL_KEY` | `PRINT_CASE_LABEL` | `true` |

---

## Replacement: Standard Maven Central Library

### Available on Maven Central

| Field | Value |
|-------|-------|
| **GroupId** | `org.cups4j` |
| **ArtifactId** | `cups4j` |
| **Latest Version** | `0.7.9` |
| **Source** | [GitHub: harwey/cups4j](https://github.com/harwey/cups4j) |
| **Maven Central** | [org.cups4j:cups4j](https://search.maven.org/artifact/org.cups4j/cups4j) |

### API Compatibility

The standard library 0.7.9 is **fully API-compatible** with the custom 0.6.4. All classes and methods used by `PrintService.java` are unchanged:

| Usage in PrintService | 0.6.4 (custom) | 0.7.9 (standard) |
|-----------------------|-----------------|-------------------|
| `new CupsClient(ip, port)` | Yes | Yes |
| `cupsClient.getPrinter(url)` | Yes | Yes |
| `new PrintJob.Builder(bytes).attributes(map).build()` | Yes | Yes |
| `cupsPrinter.print(printJob)` | Yes | Yes |
| `result.getJobId()` | Yes | Yes |
| `result.getResultCode()` | Yes | Yes |
| `result.getResultDescription()` | Yes | Yes |
| `result.isSuccessfulResult()` | Yes | Yes |
| Package: `org.cups4j.*` | Yes | Yes |

**No Java import changes or code changes are required.**

### What's Improved in 0.7.9

- Bug fixes for IPP protocol handling
- Better error messages and exception handling
- Java 11+ compatibility improvements
- Maintained and published to Maven Central (no manual jar management)

---

## Implementation Steps

### Step 1: Update `pom.xml`

**Replace** the dependency (lines 215–237):

```xml
<!-- BEFORE -->
<dependency>
    <groupId>cups4j</groupId>
    <artifactId>cups4j</artifactId>
    <version>0.6.4</version>
    <exclusions>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-api</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-nop</artifactId></exclusion>
        <exclusion><groupId>ch.qos.logback</groupId><artifactId>logback-classic</artifactId></exclusion>
    </exclusions>
</dependency>

<!-- AFTER -->
<dependency>
    <groupId>org.cups4j</groupId>
    <artifactId>cups4j</artifactId>
    <version>0.7.9</version>
    <exclusions>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-api</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId></exclusion>
        <exclusion><groupId>org.slf4j</groupId><artifactId>slf4j-nop</artifactId></exclusion>
        <exclusion><groupId>ch.qos.logback</groupId><artifactId>logback-classic</artifactId></exclusion>
    </exclusions>
</dependency>
```

**Changes:** `groupId` from `cups4j` to `org.cups4j`, `version` from `0.6.4` to `0.7.9`. Keep the SLF4J/logback exclusions — the standard library still bundles these transitive dependencies.

### Step 2: Update `Dockerfile`

**Remove** lines 6–8:

```dockerfile
# DELETE these 3 lines:
ARG LIB_FILE=cups4j-0.6.4
COPY library/${LIB_FILE}.jar /app/libs/
RUN mvn install:install-file -Dfile=/app/libs/${LIB_FILE}.jar -DgroupId=cups4j -DartifactId=cups4j -Dversion=0.6.4 -Dpackaging=jar
```

Maven will automatically download `org.cups4j:cups4j:0.7.9` from Maven Central during `mvn clean package`.

### Step 3: Update `Dockerfile_new`

Same change as Step 2 — **remove** identical lines 6–8.

### Step 4: Update `Dockerfile_old`

**No changes needed** — it has no CUPS-related lines.

### Step 5: Delete the Custom Jar

```bash
git rm library/cups4j-0.6.4.jar
```

If no other files remain in `library/`, remove the directory too:

```bash
rmdir library/   # only if empty
```

### Step 6: Verify Build

```bash
mvn clean package -DskipTests
```

Confirm Maven resolves `org.cups4j:cups4j:0.7.9` from Central successfully.

### Step 7: Run Tests

```bash
mvn test -Dtest=PrintServiceUnitTest
```

All 19 existing unit tests should pass without modification.

### Step 8: Manual Print Test (Staging/QA)

Deploy to a staging environment with CUPS server access and test:
1. Printer test via `POST /api/printer/test/{id}` endpoint
2. Inbound receiving label print
3. Picking tote label print
4. Outbound pallet label print

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| API incompatibility in 0.7.9 | **Very Low** | High | All 4 classes/methods used are unchanged; same package name |
| IPP protocol behavior change | **Low** | Medium | Test on staging with actual CUPS server before production |
| SLF4J conflict without exclusions | **Low** | Low | Keep existing exclusions in pom.xml |
| Docker build fails without jar | **None** | None | Maven Central download replaces manual install |

## Benefits

1. **Remove 2.1 MB binary from git history** — no more large jar in the repository
2. **Eliminate manual jar management** — standard Maven Central dependency resolution
3. **Faster Docker builds** — skip the `mvn install:install-file` step (~30 seconds saved)
4. **Maintainable** — receive bug fixes and security patches via version bumps
5. **No code changes** — zero risk to business logic; only build configuration changes

---

## Files Changed Summary

| File | Action |
|------|--------|
| `pom.xml` | Update groupId and version |
| `Dockerfile` | Remove 3 lines (6–8) |
| `Dockerfile_new` | Remove 3 lines (6–8) |
| `Dockerfile_old` | No change |
| `library/cups4j-0.6.4.jar` | Delete |
| `PrintService.java` | **No change** |
| All caller services | **No change** |
| All tests | **No change** |
