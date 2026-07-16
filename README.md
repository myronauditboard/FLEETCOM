# FLEETCOM

Run the **Midship**, **Cascade**, and **AuditBoard** stacks side-by-side on one
Mac, with local SSO from AuditBoard into Cascade.

Midship's ports are treated as fixed; everything else is deconflicted around
them.

**Repo locations are configurable**: on first run, `onboard.sh` prompts for
each path (Enter accepts the default) and saves your answers to a gitignored
`local.conf` that every script reads. Re-run `./onboard.sh --reconfigure` to
change them. Defaults:

```
~/midship/…                        # MIDSHIP_DIR — midship-turbo-broccoli, midship-frontend, …
~/Development/cascade              # CASCADE_DIR
~/Development/auditboard-backend   # AB_BACKEND_DIR
~/Development/auditboard-frontend  # AB_FRONTEND_DIR
~/Development/auditboard-dev-env   # AB_DEVENV_DIR (machine-learning stays nested inside)
```

## Quick start

```bash
./onboard.sh     # one-time, idempotent — applies all port/SSO config
./start-all.sh   # boots everything in dependency order (gap-filling: skips what's already up)
./doctor.sh      # port + health report
./restart-all.sh # full bounce of everything, Midship included
./stop-all.sh    # stops Cascade + AuditBoard (--midship to also stop Midship)
```

Then log into AuditBoard at **https://localhost:9002** (`ops@soxhub.com` /
`password`) and test SSO into Cascade via
**https://localhost:9002/sh/auditboardanalytics/auth** → should land on
**http://127.0.0.1:8088** authenticated. Use **Chrome** — Safari refuses the
`secure` cookie Cascade sets on plain-http 127.0.0.1.

## Port map

| Stack | Service | Port | Notes |
|---|---|---|---|
| Midship | Vite frontend | 5173 | fixed |
| Midship | FastAPI API | 8000 | fixed |
| Midship | Forge API | 8003 | fixed, situational |
| Midship | WOPI | 8080 | fixed (Docker) |
| Midship | Collabora/Onyx | 9980 | fixed (Docker) |
| Midship | Postgres | 5432 | fixed (Docker) |
| Midship | Redis | 6379 | fixed (Docker) |
| Midship | Hatchet | 1337, 7077 | fixed (Docker) |
| Midship | debugpy (opt-in) | 5678–5681, 8090 | fixed |
| AuditBoard | API v1 (Hapi) | 9001 | unchanged — Cascade hardcodes it |
| AuditBoard | Caddy HTTPS entry | 9002 | unchanged |
| AuditBoard | API v2 (Hono) + metrics | 9003, 9004 | unchanged |
| AuditBoard | login app / client Vite | 9005 / 9006 | unchanged |
| AuditBoard | **native Postgres** | **5433** | moved off 5432 (`postgresql.conf`) |
| AuditBoard | **native Redis** | **6382** | moved off 6379; 6380/6381 belong to ML redisearch |
| AuditBoard | **Conductor API** | **18080** | moved off 8080 (`devenv.override.yml`); UI stays 3000 |
| AuditBoard | **ML local service** | **8004** | moved off 8000 (`machine-learning/docker-compose.override.yml`) |
| AuditBoard | ML global / redisearch | 8001, 6380, 6381 | unchanged ML defaults |
| AuditBoard | minio, poxa, launchdevly, … | 9000/10000, 3008, 8765, 3020, 3022, 5001, 3100, 80/443, 4040, 8050, 8081–8083, 9092/9101, 9008/9009, 3001 | unchanged |
| Cascade | Django API / Daphne WS | 8010 / 8011 | unchanged — hardcoded in client `host.ts` |
| Cascade | Parcel client | 8088 | unchanged — hardcoded |
| Cascade | Postgres / MinIO | 33060 / 6010, 6011 | unchanged |
| Cascade | **Redis host publish** | **63790** | moved off 6379 (`docker-compose.override.yml`) |
| Cascade | **debugpy** | **15678–15682** | moved off 5678–5682; update attach configs |

## Where the configuration lives

| File | What | Committed? |
|---|---|---|
| `/opt/homebrew/var/postgresql@17/postgresql.conf` | `port = 5433` | system config |
| `/opt/homebrew/etc/redis.conf` | `port 6382` | system config |
| `auditboard-dev-env/.envrc` (tail block) | `DATABASE_URL`, `REDIS_URL`, `DOCKER_REDIS_URL`, `PERMISSIONS_DATABASE_URL`, `CONDUCTOR_SERVER_URL`, `AB_MLSERVICE_LOCAL_SERVICE_PORT`, `CASCADE_JWT_SECRET` | no (gitignored/generated) — **re-run `onboard.sh` after `bin/generate-config`** |
| `cascade/docker-compose.override.yml` | redis + debugpy remaps | no (`.git/info/exclude`) |
| `auditboard-dev-env/machine-learning/docker-compose.override.yml` | ML local → 8004 | ⚠ tracked file, shows as locally modified — re-apply after pulls (onboard.sh does) |
| `cascade/.env` (tail block) | `JWT_AUTH_SHARED_SECRET`, `JWT_AUTH_ISSUER`, `AB_DOMAINS`, `AB_LOGIN_URL`, `LAUNCH_DARKLY_SDK_KEY`, `LAUNCH_DARKLY_CLIENT_ID` (prompted by onboard.sh) | no (gitignored) |
| `FLEETCOM/local.conf` | per-machine repo paths (from onboard.sh prompts) | no (gitignored) |
| `FLEETCOM/devenv.override.yml` | Conductor → 18080; integrations-extract `NODE_OPTIONS=--max-old-space-size=8192` | yes (this repo) |
| Docker Desktop `settings-store.json` | Memory ≥ 12GB, disk ≥ 120GB (onboard.sh offers to apply; needs Docker restart) | system config |

## SSO in one paragraph

AuditBoard's `/api/v1/analytics/auth` signs an HS256 JWT with
`CASCADE_JWT_SECRET` and redirects to Cascade's `/auth/jwt`. Cascade verifies
it with `JWT_AUTH_SHARED_SECRET` (same value), issuer `auditboard`, audience
`http://127.0.0.1:8010/api/` (the default on both sides — do **not** set
`CASCADE_API_URL`/`CASCADE_APP_URL`, and keep `ENV_NAME=local`). Users are
auto-provisioned on first login; no Cascade seeding required.

## Troubleshooting

### AB app stalls at "Loading appears to be stalled" / blank login page

**Symptoms**: `https://localhost:9002` never finishes booting (or the login
page renders only the logo). DevTools console shows `api/v1/config` → **400**,
often followed by `Cannot read properties of undefined (reading
'session.termination.browserClosed')` and a failed Vite HMR websocket.

**Cause**: a stale `g_state` cookie (JSON blob Google Sign-In leaves on
`localhost` from *other* local projects) breaks Hapi's strict cookie parsing —
one bad cookie 400s **every** API request: `{"message":"Invalid cookie value"}`.

**Fix**: on the `localhost:9002` tab, run this in the DevTools console, then
reload:

```js
['g_state', 'intercom-device-id-m7mk7nxe'].forEach(n => {
  document.cookie = `${n}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;
  document.cookie = `${n}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; domain=localhost`;
});
```

Don't "Clear all site data" — localhost cookies are shared across ports, so a
full wipe also logs you out of Midship (5173) and drops Cascade's SSO cookie
(8088). This recurs whenever another localhost project re-plants the cookie; a
dedicated browser profile for AB work avoids it entirely. (Root-cause fix
belongs in auditboard-backend: Hapi `state.failAction: 'log'` — mention it in
#eng-dx.)

## Known edge cases
- **Cascade client crashes with LaunchDarklyFlagFetchError and lands on /404
  after SSO**: `LAUNCH_DARKLY_SDK_KEY` / `LAUNCH_DARKLY_CLIENT_ID` are missing
  from `cascade/.env` (get them from 1Password, then recreate the web
  containers and restart Parcel — or just re-run `onboard.sh`, which prompts
  for them). The SSO/JWT auth itself works without them.

- Cascade Playwright E2E starts a wiremock on host 9001 → collides with the AB
  API. Only matters when running Cascade E2E; stop the AB API first or remap
  wiremock for that run.
- `AB_MINIO_REVERSE_PROXY` (Cascade) proxies to `localhost:9000`, which is
  AuditBoard's MinIO — leave it unset locally.
- Cascade→AB reverse calls (Automations) 401 out of the box: Cascade sends JWT
  audience `http://localhost:9001` but AB expects `v1.soxhub.url`
  (`https://localhost`). Export `BASE_URL=http://localhost:9001` in the
  `.envrc` block if you need Automations; verify login redirects still work.
- `machine-learning/.envrc` comes from AWS Secrets Manager (`bin/setup_envrc`)
  and pins `REDIS_SERVICE_PORT=6380` — that's the ML redisearch container, not
  the AB Redis (6382). Don't "fix" it.
- Midship's opt-in debuggers (5678–5681) stay free because Cascade's debugpy
  moved to 15678+. Cascade `.claude/launch.json` attach configs still mention
  5678 — attach to 15678 instead.
