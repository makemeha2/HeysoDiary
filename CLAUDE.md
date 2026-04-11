# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Overview

HeysoDiary is a personal diary SPA with AI-powered feedback, polish, and chat features. The repository is a **multi-repo monorepo wrapper** — three independent sub-projects compose one running service:

| Directory | Role |
|---|---|
| `HeysoDiaryFrontEnd/` | React + Vite SPA |
| `HeysoDiaryBackEnd/` | Spring Boot API server |
| `heysoDiaryDeploy/` | Docker Compose + Nginx orchestration |
| `HeysoDiaryDocs/` | Cross-repo architecture and rule docs |

---

## Commands

### Frontend (`HeysoDiaryFrontEnd/`)

```bash
npm run dev        # Vite dev server
npm run build      # Production build
npm run lint       # ESLint
npm run preview    # Preview production build locally
```

Environment variables required: `VITE_GOOGLE_CLIENT_ID`, `VITE_API_BASE_URL`, `VITE_APP_ENV`

### Backend (`HeysoDiaryBackEnd/`)

```bash
mvn clean package        # Build JAR
mvn test                 # Run tests
mvn spring-boot:run      # Run locally
```

Backend runs on port `19090`. Requires `application-local.yaml` or env vars for DB, JWT, OpenAI, Azure Email.

### Deploy (`heysoDiaryDeploy/`)

```bash
# Development
docker compose -f compose.base.yml -f compose.dev.yml up -d

# Production override
docker compose -f compose.base.yml -f compose.prod.yml up -d
```

Dev ports: DB → `3308`, API → `19090`, Web → `8080`

---

## Architecture

### Request Flow

```
Browser → Nginx (web:80) → /api/* reverse proxy → Spring Boot (api:19090) → MariaDB (db:3306)
                         → static files served directly
```

### Authentication Flow

1. Frontend receives Google ID token via `@react-oauth/google`
2. `POST /api/auth/oauth/google` — backend validates Google token, returns JWT
3. JWT stored in localStorage via Zustand store
4. All subsequent requests: `Authorization: Bearer <token>` via `authFetch` in `src/lib/apiClient.js`
5. Spring Security JWT filter runs before `UsernamePasswordAuthenticationFilter`

Public endpoints (no auth): `/api/auth/oauth/google`, `/api/auth/validate`, Swagger, Actuator health.

### Admin Site Boundaries

- Frontend: `src/admin/**` (TypeScript, separate from user area)
- API: `/api/admin/**` (requires `scope=admin` JWT claim)
- Admin login: `POST /api/admin/auth/login` (only unauthenticated admin endpoint)
- Token key: `admin_access_token`
- Admin accounts: no registration UI — DB manual promotion only

---

## Backend Conventions

### Package Structure (domain-first)

```
heyso.HeysoDiaryBackEnd/
  auth/       diary/      diaryAi/     diaryAiPolish/
  aichat/     mypage/     comCd/       mail/
  monitoring/ ai/         security/    config/
  user/       utils/
```

Each domain may contain: `controller/`, `service/`, `dto/`, `model/`, `mapper/`, `support/`, `type/`, `security/`

### Layer Rules

- **Controller**: Request collection, `@Valid` input validation, service delegation, response. No business logic.
- **Service**: Business flow, ownership/auth checks, `@Transactional` for multi-write operations. Use `@RequiredArgsConstructor` for DI.
- **Mapper**: MyBatis XML + interface. Use `@Param` for multiple parameters. Never write SQL in service layer.

### Lombok on Models (MyBatis)

```java
@Getter @Setter @Builder @NoArgsConstructor @AllArgsConstructor
public class SomeDomainModel { ... }
```

`@NoArgsConstructor` is required for MyBatis result mapping.

### MapStruct for DTO↔Model Conversion

```java
@Mapper(componentModel = "spring", unmappedTargetPolicy = ReportingPolicy.ERROR)
public interface SomeDtoMapper {
    SomeResponse toResponse(SomeModel model);
    List<SomeResponse> toResponses(List<SomeModel> models);
}
```

Avoid `.stream().map(Dto::from)` in services — use MapStruct mappers instead.

### Response Style

- Match the **existing style of the domain** you're working in (mix of `ResponseEntity<T>`, direct DTO, and `List<T>` returns exists)
- For entirely new domains/API sets: prefer `ResponseEntity<T>`

### DB / Flyway

- All schema changes via Flyway migrations in `src/main/resources/db/migration/`
- New tables must consider: PK, FK, soft delete (`is_active`), created/updated timestamps, indexes
- Persistence is **MyBatis only** — not JPA

### AI Modules

Three separate AI domains: `aichat` (conversation), `diaryAi` (feedback), `diaryAiPolish` (text refinement). All route through the `ai/client` abstraction layer — avoid coupling domain services directly to OpenAI SDK. Always handle quota, cost, and failure cases (not just happy path).

### Security Events

Auth failures, access denials, and abnormal tokens are logged to the `monitoring` table via `MonitoringAccessDeniedHandler` and `MonitoringAuthenticationEntryPoint`. New security-significant behaviors should also write monitoring events.

---

## Frontend Conventions

### Component File Structure

```jsx
const ComponentName = () => {
  return <div>{/* content */}</div>;
};

export default ComponentName;
```

Rules:
- Component name **must match the filename**
- Always use `const Name = () => {}` (arrow function preferred)
- Always end with `export default ComponentName;` on its own line
- Never use `export default function ComponentName() {}` inline form

### State Management

- **Zustand** (`src/stores/`): auth state and global app state only
- **TanStack Query**: all server data (fetching, caching, mutations)
- Do not use Zustand for server data

### API Calls

All API calls go through `src/lib/apiClient.js` → `authFetch`. Domain API functions live in `src/pages/{domain}/api/` or domain-specific hooks.

### Path Aliases

Configured in `tsconfig.json` and `vite.config.js`:
`@/*`, `@pages/*`, `@components/*`, `@stores/*`, `@lib/*`, `@assets/*`, `@hooks/*`, `@admin/*`

---

## Language Policy

All explanations, comments, design rationale, and code review notes must be written in **Korean**. Code itself (variable names, function names, library names, keywords) stays in English.

---

## Known Inconsistencies (do not "fix" without a plan)

- Some endpoints use `POST /{id}/edit` and `POST /{id}/delete` instead of `PUT`/`DELETE` — changing these breaks frontend contracts
- No global API response envelope (`success/data/error`) — responses vary by domain
- `application-local.yaml` enables verbose logging (p6spy, Spring Security debug) — production profile is intentionally different
