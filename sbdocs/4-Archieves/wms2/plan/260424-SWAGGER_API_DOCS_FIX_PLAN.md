# Swagger/OpenAPI Documentation Fix Plan

## Current State

The project uses `springdoc-openapi-starter-webmvc-ui` v2.6.0 (correct for Spring Boot 3.5) with `io.swagger.v3.oas.annotations.tags.@Tag` on all 53 controllers. However, the Swagger UI is likely **not working** due to several configuration issues inherited from a Springfox (Swagger 2) → springdoc (OpenAPI 3) migration that was only partially completed.

---

## Issues & Fixes

### Issue 1: `@EnableWebMvc` blocks springdoc auto-configuration (CRITICAL)

**Problem:** `@EnableWebMvc` is present in 3 places:
- `StartApplication.java:24`
- `WebConfig.java:7`
- `WebConfigurer.java:29`

This annotation disables Spring Boot's `WebMvcAutoConfiguration`, which springdoc relies on for auto-registering its Swagger UI resources and `/v3/api-docs` endpoint. With `@EnableWebMvc`, Spring Boot won't serve the Swagger UI assets automatically.

**Fix:** Remove `@EnableWebMvc` from all 3 classes. Spring Boot's auto-configuration handles everything springdoc needs. The `WebMvcConfigurer` implementations (`WebConfig`, `WebConfigurer`) will still work — they just customize the auto-configured MVC setup instead of replacing it.

**Files:** `StartApplication.java`, `WebConfig.java`, `WebConfigurer.java`
**Risk:** Medium — removing `@EnableWebMvc` changes MVC setup. The `WebMvcConfigurer` implementations preserve custom behavior (content negotiation, message converters, resource handlers). Need to test that existing API responses are unchanged.

---

### Issue 2: Stale Springfox redirects and resource handlers in `WebConfig.java` (HIGH)

**Problem:** `WebConfig.java` has Springfox (Swagger 2) era configuration:
- Redirects for `/api/v2/api-docs`, `/api/swagger-resources/*` (lines 22-25) — Springfox paths
- Resource handlers for `/api/swagger-ui.html`, `/api/webjars/**` (lines 31-32) — Springfox resources
- Comment references to Springfox demos (lines 15-18)

These serve no purpose with springdoc and may cause confusion or path conflicts.

**Fix:** Remove all Swagger-related redirects and resource handlers from `WebConfig.java`. Springdoc handles its own resource serving automatically. Keep only the static resource handler (`/static/**`) if still needed.

**Also:** `configurePathMatch` with `setUseSuffixPatternMatch(false)` (line 37) — this method was **removed in Spring Framework 6** (Spring Boot 3.x). This call should be removed entirely (suffix pattern matching is disabled by default in Spring 6).

**Files:** `WebConfig.java`
**Risk:** Low — removing dead code

---

### Issue 3: Missing springdoc properties in `application.properties` (HIGH)

**Problem:** No `springdoc.*` properties exist in either `application.properties` or `application_dev.properties`. This means:
- No API metadata (title, description, version)
- Default paths (`/v3/api-docs`) conflict with the app's `/v3/` API prefix
- No grouping of endpoints (Web UI vs Mobile vs REST)

**Fix:** Add springdoc configuration to `application.properties`:

```properties
# ===============================
# SPRINGDOC / SWAGGER UI
# ===============================
# Move API docs path to avoid conflict with app's /v3/ prefix
springdoc.api-docs.path=/api-docs
springdoc.swagger-ui.path=/swagger-ui.html

# Show all endpoints, sort by tags
springdoc.swagger-ui.operationsSorter=method
springdoc.swagger-ui.tagsSorter=alpha
springdoc.swagger-ui.doc-expansion=none

# Disable Spring Data REST endpoints in docs (repos exposed via @Hidden already)
springdoc.show-spring-cloud-functions=false
```

**Files:** `application.properties`
**Risk:** None — additive configuration

---

### Issue 4: Security permits wrong paths for springdoc (HIGH)

**Problem:** `SecurityConfiguration.java` permits these Swagger paths (line 98-101):
```java
"/v2/api-docs/**", "/swagger-ui/**", "/swagger-ui.html",
"/swagger-resources/**", "/webjars/**"
```

But springdoc uses:
- `/v3/api-docs` and `/v3/api-docs/swagger-config` — **currently caught by `/v3/**` which requires `wms_user` authority**
- `/swagger-ui/**` — this one is already permitted

So unauthenticated users can load the Swagger UI page but it **fails to fetch the API spec** because `/v3/api-docs` requires auth.

**Fix:** Update security configuration to permit springdoc paths (using the new custom path from Issue 3):

```java
.requestMatchers(
    "/", "/v3", "/v3/token", "/error", "/rest/**", "/api/**",
    "/api-docs/**", "/swagger-ui/**", "/swagger-ui.html",
    "/api/public/**"
).permitAll()
```

Remove the stale Springfox paths: `/v2/api-docs/**`, `/swagger-resources/**`, `/webjars/**`.

**Files:** `SecurityConfiguration.java`
**Risk:** Low — only changes auth rules for documentation paths

---

### Issue 5: No `OpenAPI` bean — missing API metadata (MEDIUM)

**Problem:** No `@Bean OpenAPI` or `@OpenAPIDefinition` exists anywhere. The Swagger UI displays a generic "OpenAPI definition" header with no project info.

**Fix:** Create an `OpenApiConfig.java` configuration class:

```java
@Configuration
public class OpenApiConfig {
    @Bean
    public OpenAPI wmsOpenAPI() {
        return new OpenAPI()
            .info(new Info()
                .title("WMS API")
                .description("Warehouse Management System REST API")
                .version("3.5")
                .contact(new Contact().name("SiteBoss").url("https://siteboss.net")))
            .addSecurityItem(new SecurityRequirement().addList("bearer-jwt"))
            .components(new Components()
                .addSecuritySchemes("bearer-jwt",
                    new SecurityScheme()
                        .type(SecurityScheme.Type.HTTP)
                        .scheme("bearer")
                        .bearerFormat("JWT")
                        .description("Keycloak JWT token")));
    }
}
```

This enables the "Authorize" button in Swagger UI so users can test authenticated endpoints directly.

**Files:** New file: `src/main/java/net/aim_ai/wms/OpenApiConfig.java`
**Risk:** None — additive

---

### Issue 6: Endpoint grouping for better navigation (LOW)

**Problem:** All 53 controllers dump into a single flat list. The project has 3 clear domains:
- Web UI controllers (`/v3/**`) — ~40 controllers
- Mobile controllers (`/v3/mobile/**`) — 10 controllers
- REST/integration controllers (`/rest/**`) — 5 controllers

**Fix:** Add grouped API definitions in the `OpenApiConfig`:

```java
@Bean
public GroupedOpenApi webApi() {
    return GroupedOpenApi.builder()
        .group("1-web")
        .displayName("Web UI API")
        .pathsToMatch("/v3/**")
        .pathsToExclude("/v3/mobile/**")
        .build();
}

@Bean
public GroupedOpenApi mobileApi() {
    return GroupedOpenApi.builder()
        .group("2-mobile")
        .displayName("Mobile API")
        .pathsToMatch("/v3/mobile/**")
        .build();
}

@Bean
public GroupedOpenApi restApi() {
    return GroupedOpenApi.builder()
        .group("3-rest")
        .displayName("REST Integration API")
        .pathsToMatch("/rest/**")
        .build();
}
```

**Files:** `OpenApiConfig.java`
**Risk:** None — additive, Swagger UI shows a dropdown to switch groups

---

## Implementation Order

| # | Issue | Impact | Risk | Effort |
|---|-------|--------|------|--------|
| 1 | Remove `@EnableWebMvc` from 3 files | Critical — Swagger UI won't load without this | Medium | Low |
| 2 | Clean up stale Springfox code in `WebConfig.java` | High — dead code, broken `setUseSuffixPatternMatch` | Low | Trivial |
| 3 | Add `springdoc.*` properties | High — configures paths and behavior | None | Low |
| 4 | Fix security permit paths | High — API spec blocked by auth | Low | Low |
| 5 | Add `OpenApiConfig` with metadata + JWT auth | Medium — usability | None | Low |
| 6 | Add endpoint grouping | Low — navigation improvement | None | Low |

Issues 1-4 are required to make Swagger UI functional. Issues 5-6 improve usability.

---

## Testing Strategy

1. After changes, start the app and verify:
   - `GET /api-docs` returns JSON OpenAPI spec (unauthenticated)
   - `GET /swagger-ui/index.html` loads the Swagger UI (unauthenticated)
   - Swagger UI renders all controller endpoints grouped by tags
   - "Authorize" button accepts JWT token
   - Existing API endpoints still work (especially content negotiation and JSON serialization)
2. Run full test suite to check for regressions from `@EnableWebMvc` removal
