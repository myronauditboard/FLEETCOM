# FLEETCOM

Install and run the **Midship**, **Cascade**, and **AuditBoard** stacks side-by-side on one
Mac, with local SSO from AuditBoard into Cascade.

Midship's ports are treated as fixed; everything else is deconflicted around
them.

**Repo locations are configurable**: on first run, `fleetcom-onboard.sh` asks
for each repo's path, one at a time (Enter accepts the default —
`~/Development/<repo>`; tab-completion works). Answers persist to a gitignored
`local.conf` that every script reads; change them later by re-running
`./fleetcom-onboard.sh --reconfigure` or hand-editing `local.conf`. **Repos
you don't have yet are offered for cloning** (from the `soxhub` org via `gh`)
into whatever paths you chose — or point the offer at an existing checkout.
The default layout:

```
~/Development/midship-turbo-broccoli  # MIDSHIP_TURBO_BROCCOLI_DIR
~/Development/midship-frontend        # MIDSHIP_FRONTEND_DIR
~/Development/midship-onyx            # MIDSHIP_ONYX_DIR (source reference only)
~/Development/cascade                 # CASCADE_DIR
~/Development/auditboard-backend      # AB_BACKEND_DIR
~/Development/auditboard-frontend     # AB_FRONTEND_DIR
~/Development/auditboard-dev-env      # AB_DEVENV_DIR (machine-learning stays nested inside)
```

midship-onyx is cloned for source reference only — see the runtime note below.

Two repos are special at runtime: **machine-learning** is auto-cloned into
`auditboard-dev-env/` by `start-background` itself and its services start on
every AB boot (ML local :8004, global :8001). **midship-onyx** (the Collabora
fork) runs locally as the prebuilt `docviewer` ECR image via
midship-turbo-broccoli's compose (:9980) — the checkout is for source
reference/branding work; don't build it from source on macOS.

Dependency setup is automatic: `fleetcom-onboard.sh` runs `pnpm install`
(auditboard-frontend), `poetry install` (midship-turbo-broccoli), and
`npm install` (midship-frontend, cascade/client) whenever they're missing —
first run takes a while. It also offers to regenerate a stale
`auditboard-dev-env/.envrc` (backup kept, FLEETCOM settings re-applied). **Midship's Hatchet (workflow engine, ports 1337/7077) is
handled by `fleetcom-onboard.sh`** — it offers to install the hatchet CLI
(brew cask), starts the local server (`hatchet server start --dashboard-port
1337`), and copies the worker token into midship-turbo-broccoli's `.env`.

## Quick start

```bash
./fleetcom-onboard.sh     # one-time, idempotent — applies all port/SSO config
                          # first time? seed the AB database too — see "Database seeding"
./fleetcom-onboard.sh --reconfigure   # change repo locations later
./fleetcom-start-all.sh   # boots everything in dependency order (gap-filling: skips what's already up)
./fleetcom-doctor.sh      # port + health report
./fleetcom-logs.sh        # live backend log panes + error alerts (auto-opens after start-all)
./fleetcom-restart-all.sh # full bounce of everything, Midship included
./fleetcom-stop-all.sh    # stops Cascade + AuditBoard (--midship to also stop Midship)
```

Then log into AuditBoard at **https://localhost:9002** (`ops@soxhub.com` /
`password`) and test SSO into Cascade via
**https://localhost:9002/sh/auditboardanalytics/auth** → should land on
**http://127.0.0.1:8088** authenticated. Use **Chrome** — Safari refuses the
`secure` cookie Cascade sets on plain-http 127.0.0.1.

## Watching logs

`fleetcom-start-all.sh` ends by opening the four log streams — the first run
asks whether you prefer a **tmux** session (one window, 2×2 grid) or **four
separate Terminal windows**; the answer persists in `local.conf` (`LOGS_VIEW`)
and can be switched anytime with `./fleetcom-logs.sh --tmux` /
`--windows`. Reopen with `./fleetcom-logs.sh`; skip the auto-open with
`./fleetcom-start-all.sh --no-logs`. The streams:

| | |
|---|---|
| **optro-api** — AB backend (`logs/ab-api.log`) | **midship-api** (`logs/midship-api.log`) |
| **cascade** — docker logs (web/ws/c3) | **alerts** — ERROR/WARN merged from all three |

tmux basics: `Ctrl-b d` detaches (servers keep running), `./fleetcom-logs.sh`
reattaches, `./fleetcom-logs.sh --kill` closes the panes; mouse scrolling is
enabled; `fleetcom-stop-all.sh` closes the session automatically. Windows
mode: each stream opens as an Apple Terminal window (generated
`logs/win-*.command` files — double-click to re-open one); closing a window
stops its tail, and windows mode is also the automatic fallback when tmux
isn't installed. The client logs (`ab-client.log`, `midship-frontend.log`,
`cascade-client.log`) also live in `FLEETCOM/logs/` for manual tailing.

## Using your own start commands (start-all is optional)

Onboarding changes *machine state* — ports, env files, secrets, dependencies —
not how you launch things. After `fleetcom-onboard.sh` you can run every stack
the way its own README describes, and `fleetcom-doctor.sh` / `fleetcom-logs.sh`
/ `fleetcom-stop-all.sh` still work (they operate on ports and containers, not
on how services were started). Two caveats:

- **Conductor (AB)**: native `abc run start-background` starts it on **8080**,
  which collides with Midship's WOPI and mismatches `.envrc`'s
  `CONDUCTOR_SERVER_URL` (18080). Native-compatible form:
  `abc run start-background -- -s conductor`, then
  `docker compose -f docker-compose-supplement-dev.yml -f ../FLEETCOM/devenv.override.yml up -d conductor`.
- **Cascade's server image**: the compose override pins locally-built
  `local_test_web:latest`, so build it once
  (`docker-compose -f docker-compose.yml -f docker-compose-build.yml build`)
  before a purely native `docker-compose up`. The port overrides themselves
  need nothing special — plain `docker-compose up` auto-loads
  `docker-compose.override.yml`.

Also fine to mix: e.g. run the AB API in your own terminal (better turbo TUI
experience) while FLEETCOM manages everything else — the log pane will note
that its output isn't captured.

## Database seeding

Two stacks have dump-based seeding, with **different conventions** — don't mix
the files up:

| | AuditBoard | Midship |
|---|---|---|
| Dump location | `<auditboard-dev-env>/workspace/` | `<midship>/midship-turbo-broccoli/db/` |
| File types | `.dump` (pg_restore) / `.sql` (psql) | plain `.sql` (`dev_dump_YYYY_MM_DD.sql`) |
| Import command | `abc db reset` | `poetry run python scripts/load_db_dump.py db/<file>` |
| Target DB | native Postgres :5433 (`demo_data`) | Docker Postgres :5432 |
| ⚠ Gotcha | `.dump` beats `.sql` in default resolution | dumps may embed the dev DB password in a `\restrict` line — strip it |

`fleetcom-onboard.sh` prompts for both, each gated by an up-front
`seed/reseed? [y/N]` question (default **No** — pressing Enter skips the whole
thing safely). Answering yes gets a dump-path prompt (tab-completion, retry on
typos, workspace/db default) and a final type-`reset` confirmation before the
destructive import. Midship `\restrict` password-stripping is automatic. The
import is a **one-time seed / occasional refresh** — daily boots only run
migrations on top.

### AuditBoard details

The AB demo data comes from a **SQL data dump imported once** — it is *not*
part of the daily boot. Regular starts (`fleetcom-start-all.sh` → `bin/start-api`) only
run migrations on top of whatever is already in the database.

- `fleetcom-onboard.sh` handles this: it prompts for a dump path (e.g. one you
  downloaded to `~/Downloads`), defaulting to what's in
  `<auditboard-dev-env>/workspace/`. A mistyped path re-prompts (Enter falls
  back to the default); a valid path is copied into `workspace/` for future
  use. It then asks you to type `reset` before importing — because the import
  is **destructive**: it drops and replaces the whole `demo_data` DB,
  including any local AB state. Seed login afterwards: `ops@soxhub.com` /
  `password`. Keep the file's original extension — it selects the import tool
  (`.dump` → `pg_restore`, `.sql` → `psql`); renaming a `.sql` to `.dump`
  breaks the import.
- Workspace precedence (when several dumps exist): the alphabetically-last
  `.dump` wins over `.sql.zip` over `.sql`, regardless of age — an explicitly
  entered path bypasses this. No dump anywhere? Ask a teammate for the current
  platform dataset — without one, `reset-db` falls back to a minimal empty seed.
- Manual alternative: `abc db reset` from `auditboard-dev-env`
  (`DATA_DUMP_FILE=/path/to/dump.sql` to pick a specific file).
- When to run: first-time setup, or whenever you want to refresh to the
  canonical dataset. Cascade's DB is separate and unaffected — it seeds via
  its own `migrate` + `bootstrap`, and SSO users auto-provision on first login.

### Midship details

- Dumps come from the dev RDS instance (see midship-turbo-broccoli README →
  "Load a Full Dev Database Dump" for the bastion/pg_dump recipe) and are
  named `dev_dump_YYYY_MM_DD.sql`. They're gitignored in `db/` — real data,
  ~30-40MB.
- **Security**: fresh dumps can contain the dev DB password in a `\restrict`
  line. `fleetcom-onboard.sh` strips it while copying into `db/`; if you handle a dump
  manually, run `sed -i '' '/^\\restrict/d' <file>` first and delete the
  unsanitized original.
- The import (`scripts/load_db_dump.py`) drops the DB and can't do so under
  active connections — `fleetcom-onboard.sh` stops the Midship API first; bring it back
  afterwards with `./fleetcom-start-all.sh`.

## Automations / Analytics (Cascade) in AuditBoard

The AB Automations module (workspace → Automations) is powered by Cascade plus
the `integrations-extract` side service. FLEETCOM handles the plumbing:

- `fleetcom-onboard.sh` backfills the credential-encryption keys into
  `.envrc` when it predates the key rotation (see Troubleshooting: "Invalid
  key length"), and sets `EXTRACT_HOST` in `cascade/.env` so Cascade can reach
  integrations-extract.
- `fleetcom-start-all.sh` already boots in the required order — extract (with
  the AB background services) **before** Cascade — so Cascade's manager can
  initialize its ExtractClient. After onboard adds `EXTRACT_HOST`, the next
  start-all recreates Cascade's containers with it automatically.

**One-time manual step — app state, not env config**: log into AB → Settings →
Site Configuration → **Features** (Superuser group) → scroll to the
**Automation** heading → enable **Analytics** (the older Coda guide says
Insider Access → "Auditboard Analytics"; that toggle has moved to Features).
This lives in the AB *database*, so re-check it after every `demo_data` reseed
(dumps may or may not include it). It cannot be scripted safely from outside
the app.

**Optional — Merge.dev connectors** (Paylocity etc.): `MERGE_API_KEY`
(1Password) in `.envrc`, plus LaunchDarkly flags `merge-dev-integrations`,
`integrations-extract-service-enabled`, and `show-all-integrations` — served
locally by LaunchDevly (:8765). Extract's API docs: `localhost:3001/docs`.

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
| Midship | Hatchet | 1337, 7077 | fixed (Docker) — set up separately per midship-turbo-broccoli README; FLEETCOM restarts existing containers but cannot create them |
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
| `auditboard-dev-env/.envrc` (tail block) | `DATABASE_URL`, `REDIS_URL`, `DOCKER_REDIS_URL`, `PERMISSIONS_DATABASE_URL`, `CONDUCTOR_SERVER_URL`, `AB_MLSERVICE_LOCAL_SERVICE_PORT`, `CASCADE_JWT_SECRET` | no (gitignored/generated) — **re-run `fleetcom-onboard.sh` after `bin/generate-config`** |
| `cascade/docker-compose.override.yml` | redis + debugpy remaps | no (`.git/info/exclude`) |
| `auditboard-dev-env/machine-learning/docker-compose.override.yml` | ML local → 8004 | ⚠ tracked file, shows as locally modified — re-apply after pulls (fleetcom-onboard.sh does) |
| `cascade/.env` (tail block) | `JWT_AUTH_SHARED_SECRET`, `JWT_AUTH_ISSUER`, `AB_DOMAINS`, `AB_LOGIN_URL`, `LAUNCH_DARKLY_SDK_KEY`, `LAUNCH_DARKLY_CLIENT_ID` (prompted by fleetcom-onboard.sh, get from 1Password > QE Team Vault > Cascade base env file) | no (gitignored) |
| `FLEETCOM/local.conf` | per-machine repo paths (from fleetcom-onboard.sh prompts) | no (gitignored) |
| `FLEETCOM/devenv.override.yml` | Conductor → 18080; integrations-extract `NODE_OPTIONS=--max-old-space-size=8192` | yes (this repo) |
| Docker Desktop `settings-store.json` | Memory ≥ 12GB, disk ≥ 120GB (fleetcom-onboard.sh offers to apply; needs Docker restart) | system config |

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

**Cause**: the `g_state` cookie that **Midship's own Google Sign-In** plants on
`localhost` (GIS One-Tap state, a JSON blob; see midship-frontend
`SignIn.tsx`). Cookies ignore ports, so signing into Midship at `:5173` puts
it on every localhost app — and Hapi's strict cookie parsing 400s **every**
AB API request over one bad cookie: `{"message":"Invalid cookie value"}`.
AB-only developers never see this; it's inherent to running Midship + AB in
one browser profile.

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

### AB API v2 serves stale code after editing backend files (EADDRINUSE :9004)

**Symptoms**: you edit `auditboard-backend`, packages rebuild, but changes
don't take effect on `/api/v2/*`; the alerts pane / `logs/ab-api.log` shows
`Error: listen EADDRINUSE: address already in use :::9004`.

**Cause**: turbo watch only kills the old `api:v2` process on rebuild-restart
when the API has a **controlling terminal**. FLEETCOM originally launched it
detached (`nohup`), so the old process leaked, the rebuilt v2 lost the port
race and died, and the stale process kept serving pre-edit code. (Verified by
A/B experiment: identical edits restart cleanly under a pty, leak without one.)

**Fix (already in place)**: `fleetcom-start-all.sh` runs the API inside a
detached tmux session (`fleetcom-ab-api`), which provides the pty — restarts
are clean. `tmux attach -t fleetcom-ab-api` shows the raw process if you ever
want it. If you see this error anyway, the API was probably started by hand
with `nohup`/backgrounding — bounce it: kill whatever holds 9001/9003 and
re-run `./fleetcom-start-all.sh`.

### Workflows page is empty / shows "Install and configure services from the new Integrations module"

The Analytics service isn't enabled for this AB site. Enable it in the app:
Settings → Site Configuration → **Features** (Superuser group) → **Automation**
heading → enable **Analytics** (details in the "Automations / Analytics"
section above; older docs point at Insider Access — the toggle moved). This is stored in the AB database — it can silently disappear
after a `demo_data` reseed, so re-check it there first whenever the
Automations module looks unconfigured.

### Automations page: "an error occurred while decrypting: RangeError: Invalid key length"

**Cause**: your generated `.envrc` predates the credential-encryption key
rotation (SOX-88587) and lacks `SHARED_EXTERNAL_ENCRYPTION_KEY` /
`EXTERNAL_SECRET_ENCRYPTION_KEY` — the backend decrypts stored automation
credentials with an empty key. **Fix**: re-run `./fleetcom-onboard.sh` (it
backfills both from `bin/generate-config`), then restart the AB API and
recreate `integrations-extract` so both pick up the keys. If a *different*
decrypt error appears afterwards ("bad decrypt"), the seeded credentials were
encrypted with a non-standard key — delete those automation-credential rows
and recreate them in the UI.

### doctor shows Hatchet (1337 / 7077) NOT LISTENING

Hatchet is Midship's self-hosted workflow engine (compose project
`hatchet-cli`). Re-run `./fleetcom-onboard.sh` — it installs the hatchet CLI,
starts the local server on the right ports, and copies the worker token into
midship's `.env`. Midship boots fine without it, but the document-processing
pipeline (Hatchet workers) won't run until it's up.

## Known edge cases
- **Cascade client crashes with LaunchDarklyFlagFetchError and lands on /404
  after SSO**: `LAUNCH_DARKLY_SDK_KEY` / `LAUNCH_DARKLY_CLIENT_ID` are missing
  from `cascade/.env` (get them from 1Password > QE Team Vault > Cascade base
  env file, then recreate the web containers and restart Parcel — or just
  re-run `fleetcom-onboard.sh`, which prompts for them). The SSO/JWT auth itself works
  without them.

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
