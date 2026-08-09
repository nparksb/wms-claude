# OWL Monorepo

Multi-project monorepo for the SiteBoss OWL platform — an order management and warehouse management system (OMS + WMS) spanning two major versions (v1 legacy, v2 modern).

## Repository Structure

```
owl/
├── v1/                          # Legacy stack
│   ├── oms/                     # OMS — PHP 5.6, Zend Framework 2
│   ├── wms-api/                 # WMS API — Java 8, Spring Boot 2.3.7, Maven, PostgreSQL
│   ├── wms-web-ui/              # WMS Web UI — Nuxt 2, Vue 2, Vuetify 2
│   └── wms-mobile-ui/          # WMS Mobile UI — Nuxt 2, Vue 2, Vuetify 2
├── v2/                          # Modern stack
│   ├── oms-laravel-api/         # OMS API — PHP 8.4, Laravel 12, MySQL + MongoDB
│   ├── wms2-api/                # WMS API — Java 21, Spring Boot 3.5.9, Maven, PostgreSQL
│   ├── omsv2-UI/                # OMS UI — React 18, TypeScript, Vite 5, MUI v7 + shadcn
│   ├── wms2-web-ui/             # WMS Web UI — Nuxt 2, Vue 2, Vuetify 2
│   └── wms2-mobile-ui/         # WMS Mobile UI — Nuxt 2, Vue 2, Vuetify 2
├── sbdocs/                      # Obsidian vault — PARA-organized documentation
│   ├── 0-Inbox/                 # Temporary landing zone (should be empty)
│   ├── 1-Projects/              # Active plans and investigations
│   │   ├── wms1/plan/           # WMS v1 active bug fix / feature plans
│   │   └── wms2/plan/           # WMS v2 active bug fix / feature plans
│   ├── 2-Areas/                 # Ongoing responsibilities (runbooks, operations)
│   ├── 3-Resources/             # Reusable reference material
│   │   ├── architecture/        # Entity reports, package analysis
│   │   ├── workflows/           # Business process docs (replenish, club orders)
│   │   └── reports/             # Project-level analysis reports
│   ├── 4-Archieves/             # Completed/inactive work
│   │   ├── wms1/plan/           # WMS v1 completed plans
│   │   ├── wms1/analysis/       # WMS v1 closed investigations
│   │   └── wms2/plan/           # WMS v2 completed plans
│   └── 9-System/templates/      # Plan template with Dataview YAML frontmatter
└── .claude/
    └── skills/                  # Repo-local Claude Code skills (see "Custom Skills" below)
```

## Documentation Vault

The `sbdocs/` directory is an Obsidian PARA vault — the source of truth for architecture, design decisions, workflows, and active/archived plans.

- **Entry point**: `sbdocs/INDEX.md` — start here to navigate the vault
- **Architecture docs**: `sbdocs/3-Resources/architecture/` — entity reports, package analysis, request journey, state machine catalog, transaction/OSIV maps, scheduled jobs, tenant routing topology
- **Design docs**: `sbdocs/3-Resources/design/` — module-level class design, data models, API contracts
- **Active plans**: `sbdocs/1-Projects/wms1/plan/` and `sbdocs/1-Projects/wms2/plan/`
- **Archived plans**: `sbdocs/4-Archieves/wms1/plan/` and `sbdocs/4-Archieves/wms2/plan/`

**Before any non-trivial change**, check `sbdocs/3-Resources/architecture/` and `sbdocs/3-Resources/design/` for existing analysis of the affected subsystem. Check `sbdocs/1-Projects/` and `sbdocs/4-Archieves/` for prior plans that touched the same symbols. Do not re-derive what is already documented.

**For bug fixes and new feature planning** (except very small/trivial tasks), read the relevant doc sections **before writing any code or plan**:
1. Grep `sbdocs/3-Resources/architecture/wms1-function-to-docs-map.md` (v1) or `wms2-function-to-docs-map.md` (v2) to find which docs apply. Grep **by the axis you actually have**:
   - **Class name** (`CycleCountController`, `CyclecountService`) → the v2 map's §9 *API Symbol → Doc Index* covers all 61 controllers plus each subsystem's primary services. Grep the enclosing **class**, not a method name — method names are deliberately not indexed.
   - **Feature name, page path, or endpoint** (`cycle-count`, `/cycleCountLos/`) → §2–§8, which is a complete enumeration of both UIs' menu-reachable pages. Use this axis when the class grep misses.
   - **A miss means "not indexed", not "no docs exist."** Before concluding no doc applies, check `ls sbdocs/3-Resources/workflows/` and `design/` for the subsystem by name.
   - Both maps carry the symbol axis at **§9**, with different coverage: v1's *Service Method → Doc Index* lists 18 hot **services** with file paths and section pointers but **no controllers** (grep a v1 controller and you will miss — jump to the service or the endpoint axis); v2's *API Symbol → Doc Index* covers all 61 controllers plus each subsystem's primary services, grouped by subsystem.
2. Read the implicated sections (targeted `offset+limit` read) before proceeding.
3. Skip only for single-line fixes, renames, or trivial config changes.

`sbdocs/` is NOT in git — use plain `mv` (never `git mv`) for file operations inside it.

## Custom Skills (repo-local)

Custom Claude Code skills used by this repo live at `owl/.claude/skills/<skill-name>/SKILL.md`. They are **not** in the global `~/.claude/skills/` directory — they ride with the repo so cross-machine sessions pick up the same prompts.

| Skill | Purpose |
|-------|---------|
| `wms-bugfix-plan` | Produce a deeply-grounded bug-fix plan into `sbdocs/1-Projects/wms{1\|2}/plan/`, then chain into `wms-tdd-gate` |
| `wms-feature-plan` | Produce a feature/refactor plan into `sbdocs/1-Projects/wms{1\|2}/plan/`, then chain into `wms-tdd-gate` |
| `wms-tdd-gate` | Create the per-ticket worktree, write failing tests from a reviewed plan's acceptance criteria, confirm correct failures, pause for approval before implementation. Runs automatically as the last phase of the two plan skills; also runnable standalone |
| `wms-plan-executor` | Execute a reviewed plan in a per-ticket worktree off fresh `origin/develop`: ralph-loop to green, code review + fix High/Medium, verify-docs, commit, PR into `develop`, update plan doc + ClickUp to `pr submitted`. Stops at PR — does not merge, deploy, or archive |

**Implementation worktrees:** `wms-tdd-gate` and `wms-plan-executor` never write code into the main sub-repo checkouts. Both work in `.claude/worktrees/<repo-dir-name>/<TICKET>` (git-ignored), branched off freshly-fetched `origin/develop`, one per repo per ticket — so `v2/wms2-api` and friends stay on whatever branch you left them on. Verify scripts must be run with `PROJECT_ROOT` pointed at a symlink shadow root (recipe in `wms-plan-executor`), otherwise they grade the main checkout instead of the work.
| `wms-investigation-report` | Produce an evidence-based investigation report into `sbdocs/3-Resources/reports/` |
| `wms-architecture-doc` | Produce a system-level architecture doc into `sbdocs/3-Resources/architecture/` |
| `wms-design-doc` | Produce a module-level design doc into `sbdocs/3-Resources/design/` |
| `wms-v2-migrate` | Port a v1 plan to a v2 plan in `sbdocs/1-Projects/wms2/plan/` |
| `wms-v1-sync-sweep` | Coordinate the weekly v1→v2 sync sweep across the three v1 repos |
| `archive-plan` | Move a completed plan from `1-Projects/` to `4-Archieves/`, flip status, update READMEs, retire the verify script, and remove the per-ticket implementation worktree(s) |
| `refresh-moc` | Audit folder-level READMEs (MOCs) against the filesystem and report drift |
| `verify-docs` | Audit `sbdocs/` for drift against the code |
| `broken-links` | Scan `sbdocs/` for broken cross-references |

**Plan filename convention** (codified in the plan-generating skills above):
- Untracked plans: `YYMMDD-kebab-description.md` (e.g., `260424-runclubline-transaction-boundary-hardening.md`).
- Ticketed plans: `SBDEV-####-kebab-description.md` (no date prefix; the ticket is the sortable identifier).
- Reports: `YYMMDD-kebab-description.md`.
- v1↔v2 plan pairs share the **same base name** (including prefix) for easy pairing.

When updating skill behavior, edit `owl/.claude/skills/<skill-name>/SKILL.md` directly.

## Project-Specific CLAUDE.md Files

Each sub-project has its own `CLAUDE.md` with detailed architecture, patterns, and conventions. **Always read the sub-project's CLAUDE.md before working in that directory.**

| Project | CLAUDE.md | Status |
|---------|-----------|--------|
| `v1/oms` | `v1/oms/CLAUDE.md` | Comprehensive |
| `v1/wms-api` | `v1/wms-api/CLAUDE.md` | Comprehensive |
| `v2/oms-laravel-api` | `v2/oms-laravel-api/CLAUDE.md` | Comprehensive |
| `v2/wms2-api` | `v2/wms2-api/CLAUDE.md` | Comprehensive |
| `v2/omsv2-UI` | `v2/omsv2-UI/CLAUDE.md` | Comprehensive |
| `v2/wms2-web-ui` | `v2/wms2-web-ui/CLAUDE.md` | Comprehensive |

## Tech Stack Summary

### v1 (Legacy)

| Project | Language | Framework | Database | Port |
|---------|----------|-----------|----------|------|
| oms | PHP 5.6 | Zend Framework 2 | MySQL (multi-tenant) | 80/443 |
| wms-api | Java 8 | Spring Boot 2.3.7 | PostgreSQL | 8088 (dev), 8080 (prod) |
| wms-web-ui | JavaScript | Nuxt 2.15 / Vue 2 / Vuetify 2 | — | 3000 |
| wms-mobile-ui | JavaScript | Nuxt 2.15 / Vue 2 / Vuetify 2 | — | 3001 |

### v2 (Modern)

| Project | Language | Framework | Database | Port |
|---------|----------|-----------|----------|------|
| oms-laravel-api | PHP 8.4 | Laravel 12 | MySQL + MongoDB | 8000 |
| wms2-api | Java 21 | Spring Boot 3.5.9 | PostgreSQL | 8088 (dev), 8080 (prod) |
| omsv2-UI | TypeScript | React 18 / Vite 5 / MUI v7 | — | 8080 |
| wms2-web-ui | JavaScript | Nuxt 2.15 / Vue 2 / Vuetify 2 | — | 3000 |
| wms2-mobile-ui | JavaScript | Nuxt 2.15 / Vue 2 / Vuetify 2 | — | 3001 |

## Authentication

All projects use **Keycloak** (OpenID Connect / OAuth2) for authentication:
- **v1/oms**: Apache `mod_auth_openidc` proxy + HTTP basic auth for API
- **v1/wms-api**: Spring Security OAuth2 + Keycloak adapter (per-tenant JWT)
- **v2/oms-laravel-api**: Keycloak SSO (JWT) + API key fallback
- **v2/wms2-api**: Spring Security OAuth2/OIDC + per-tenant Keycloak JWT
- **Frontend apps**: `vue-keycloak-js` plugin (Vue/Nuxt) or custom React integration

## Multi-Tenancy

All backends implement **database-level multi-tenancy**:
- **v1/oms**: Each client gets a separate MySQL schema with 3 adapters (master, replica, reporting-UTC)
- **v1/wms-api**: HTTP headers `tenant_name` + `facility_code` → dynamic datasource routing
- **v2/oms-laravel-api**: Spatie Laravel Multitenancy (database-per-tenant: tenant, landlord, reporting, MongoDB)
- **v2/wms2-api**: HTTP headers `tenant_name` + `facility_code` → 4-char routing key → dynamic datasource

## Quick Reference — Build & Run

### v1/oms (PHP/ZF2)
```bash
cd v1/oms
docker-compose up                    # Start Apache + PHP containers
make all                             # Build stored procedures
python sql/apply_patches.py --alldb --dir sql/patches  # Apply DB patches
tests/run_all_tests.sh               # Run all tests
```

### v1/wms-api (Java 8 / Spring Boot)
```bash
cd v1/wms-api
mvn clean package -DskipTests        # Build JAR
mvn spring-boot:run                  # Run locally
mvn test                             # Run tests
mvn verify                           # Integration tests (Testcontainers)
```

### v1/wms-web-ui (Nuxt 2)
```bash
cd v1/wms-web-ui
yarn install && yarn dev             # Dev server :3000
yarn build && yarn start             # Production
yarn test                            # Jest tests
```

### v1/wms-mobile-ui (Nuxt 2)
```bash
cd v1/wms-mobile-ui
yarn install && yarn dev             # Dev server :3001
yarn build && yarn start             # Production
```

### v2/oms-laravel-api (Laravel 12)
```bash
cd v2/oms-laravel-api
composer dev                         # Full stack (server + queue + logs + Vite)
php artisan serve                    # API server :8000
php artisan test                     # PHPUnit tests
./vendor/bin/pint                    # Code formatting (PSR-12)
php artisan l5-swagger:generate      # Regenerate OpenAPI docs
docker-compose up -d                 # Docker stack (app, nginx, redis, mongo, reverb)
```

### v2/wms2-api (Java 21 / Spring Boot)
```bash
cd v2/wms2-api
mvn clean package -DskipTests        # Build JAR
mvn spring-boot:run                  # Run locally
mvn test                             # Run tests
mvn verify                           # Integration tests (Testcontainers)
```

### v2/omsv2-UI (React 18)
```bash
cd v2/omsv2-UI
npm install && npm run dev           # Dev server :8080
npm run build                        # Production build
npm run lint                         # ESLint
```

### v2/wms2-web-ui (Nuxt 2)
```bash
cd v2/wms-web-ui
yarn install && yarn dev             # Dev server :3000
yarn build && yarn start             # Production
yarn test                            # Jest tests
```

### v2/wms2-mobile-ui (Nuxt 2)
```bash
cd v2/wms2-mobile-ui
yarn install && yarn dev             # Dev server :3001
yarn build && yarn start             # Production
```

## File-size heuristic — when to grep vs Read

This monorepo has many large service files (e.g., `v1/wms-api/src/main/java/net/aim_ai/wms/service/BillofladingService.java` is ~1200 lines, several other services are ≥600 lines). Per the global directive in `~/.claude/CLAUDE.md`, default to grep, but tighten the project-scoped threshold:

- Any file under `v1/wms-api/src/` or `v2/wms2-api/src/` that's ≥600 lines: grep first, never full Read.
- Any controller / service / repository file with `@Service` / `@Repository` / `@RestController` annotations is presumed structurally large enough to warrant a `wc -l` check before Reading.
- For edit prep on a large service, the workflow is:
  1. `grep -n "<symbol>"` to find the hunk's line range.
  2. `Read` with `offset` + `limit` covering ~30 lines around the hunk.
  3. `Edit`.
- For "what does this method do?" questions, prefer a targeted Read with `offset` + `limit` over a full Read. The whole `BillofladingService.closeBOL` body is ~400 lines on its own — don't pull more than the relevant phase into context.

When in doubt, announce the intent ("Reading `BillofladingService.java` lines 555-625 to inspect Phase 8") so the user can override before the Read fires.

## Git & CI/CD

- The `owl/` monorepo umbrella is **not** itself a git repository — it is a locally-maintained working directory that groups the sub-project clones for convenience.
- `sbdocs/` is also **not** in git — it is a locally-maintained Obsidian vault. Treat it as filesystem-only: use plain `mv` (not `git mv`) when archiving plans, and never assume you can recover an `sbdocs/` change via `git checkout`.
- Each sub-project (e.g. `v1/wms-api`, `v2/oms-laravel-api`, `v2/omsv2-UI`) **is** its own independent git repository nested inside this monorepo. Git operations belong inside those sub-project directories.
- **Branching**: main/develop/feature/* pattern
- **CI/CD**: GitLab CI with tag-driven deployments (dev-*, qa-*, ua-*, v* for production)
- **v2/oms-laravel-api** and **v2/omsv2-UI** use GitHub Actions

## Key Architectural Patterns

### Backend APIs
- **v1/wms-api**: No JPA association annotations — manual FK relationships only. Entity comparison by ID, not `.equals()`. Mockito 3.3.3 (no `mockStatic()`).
- **v2/wms2-api**: Same patterns as v1/wms-api but on Java 21 / Spring Boot 3.x. Uses Caffeine caching, Micrometer metrics, Zipkin tracing.
- **v1/oms**: Stored procedures for business logic (allocation, billing, reports). SQL changes require `make` rebuild.
- **v2/oms-laravel-api**: Controllers → Services → Repositories → Models. 40+ carrier integrations. Laravel Reverb WebSockets.

### Frontend Apps
- **Nuxt/Vue apps** (wms-web-ui, wms-mobile-ui): Vuex state management, Keycloak auth plugin, axios with retry, Vuetify 2 Material Design.
- **omsv2-UI** (React): MUI v7 + shadcn/ui dual library strategy, TanStack React Query, React Hook Form + Zod validation.

## Environment & Secrets

- All projects use `.env` files for configuration (gitignored)
- Keycloak URLs, realms, and client IDs are environment-specific
- **v1/wms-api** and **v2/wms2-api**: Jasypt encryption for sensitive properties (`ENC(...)` format, requires `-Djasypt.encryptor.password`)
- Never commit `.env`, `auth.json`, `config.php`, `local.php`, or `*_dev.properties` files

## API Documentation

| Project | Docs |
|---------|------|
| v1/oms | OpenAPI YAML in `htdocs/api_docs/` |
| v1/wms-api | Swagger UI at `/api/swagger-ui.html` |
| v2/oms-laravel-api | L5-Swagger, auto-generated |
| v2/wms2-api | SpringDoc at `/swagger-ui/index.html` |
