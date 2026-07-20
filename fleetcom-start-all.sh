#!/bin/bash
# FLEETCOM: boot Midship, AuditBoard, and Cascade in dependency order.
# Skips anything already running (checks the port first). Long-running dev
# servers are nohup'd with logs in ./logs/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"
MIDSHIP="$MIDSHIP_DIR"
LOGS="$HERE/logs"
mkdir -p "$LOGS"

say() { printf '\033[36m[start-all]\033[0m %s\n' "$*"; }
up()  { lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# --- Midship (fixed ports; owns 5432/6379/8080/9980/8000/5173) --------------
if [ -d "$MIDSHIP/midship-turbo-broccoli" ]; then
	say "midship: docker services"
	(cd "$MIDSHIP/midship-turbo-broccoli" && docker compose up -d)
	# hatchet lives in its own compose project (hatchet-cli); restart its
	# containers if fleetcom-stop-all.sh --midship (or a reboot) stopped them
	HATCHET_STOPPED=$(docker ps -aq --filter "name=hatchet-cli" --filter "status=exited" 2>/dev/null)
	[ -n "$HATCHET_STOPPED" ] && docker start $HATCHET_STOPPED >/dev/null && say "restarted hatchet containers"
	if up 8000; then say "midship API already on 8000"; else
		say "midship API -> logs/midship-api.log"
		(cd "$MIDSHIP/midship-turbo-broccoli" && ENV=local_db nohup poetry run uvicorn midship.app.main:app --reload > "$LOGS/midship-api.log" 2>&1 &)
	fi
	if up 5173; then say "midship frontend already on 5173"; else
		say "midship frontend -> logs/midship-frontend.log"
		(cd "$MIDSHIP/midship-frontend" && nohup npm run dev > "$LOGS/midship-frontend.log" 2>&1 &)
	fi
else
	say "midship not found at $MIDSHIP — skipping"
fi

# --- AuditBoard --------------------------------------------------------------
say "AB native databases (postgres 5433, redis 6382)"
up 5433 || launchctl kickstart gui/$(id -u)/homebrew.mxcl.postgresql@17
up 6382 || launchctl kickstart gui/$(id -u)/homebrew.mxcl.redis

say "AB background services (conductor + integrations-extract start separately with local overrides)"
(cd "$DEVENV" && abc run start-background -- -s conductor,integrations-extract)
(cd "$DEVENV" && direnv exec . docker compose -f docker-compose-supplement-dev.yml \
	-f "$HERE/devenv.override.yml" up -d conductor integrations-extract)

if up 9001; then say "AB API already on 9001"; else
	say "AB API -> logs/ab-api.log (migrations + api/worker/cron; takes a few minutes)"
	(cd "$AB_BACKEND_DIR" && nohup direnv exec . bin/start-api > "$LOGS/ab-api.log" 2>&1 &)
fi

# Probe Vite (9006), not Caddy (9002): the caddy docker container outlives a
# dead Vite process, so 9002 alone gives a false "already running".
if up 9006; then say "AB client already on 9006"; else
	say "AB client -> logs/ab-client.log (ope dev from monorepo root; --reuse-last avoids the TTY prompt)"
	(cd "$AB_FRONTEND_DIR" && nohup direnv exec "$DEVENV" pnpm start --reuse-last > "$LOGS/ab-client.log" 2>&1 &)
fi

# --- Cascade -----------------------------------------------------------------
say "cascade: docker services (local image build; staged startup — parallel first-time"
say "  layer extraction of the 2.6GB server image can transiently fill the Docker VM disk)"
(cd "$CASCADE" \
	&& { docker image inspect local_test_web:latest >/dev/null 2>&1 \
		|| docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml build; } \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d db redis store \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d web \
	&& docker-compose -f docker-compose.yml -f docker-compose-build.yml -f docker-compose.override.yml up -d)
say "cascade: migrations"
docker exec cascade_web python manage.py migrate --no-input || say "migrate failed — is web still starting? retry: docker exec cascade_web python manage.py migrate"

if up 8088; then say "cascade client already on 8088"; else
	say "cascade client -> logs/cascade-client.log (node pinned from .nvmrc via volta or nvm)"
	if command -v volta >/dev/null; then
		(cd "$CASCADE/client" && nohup volta run --node "$(cat .nvmrc)" npm start > "$LOGS/cascade-client.log" 2>&1 &)
	else
		(cd "$CASCADE/client" && nohup bash -lc 'source ~/.nvm/nvm.sh && nvm install && nvm use && npm start' > "$LOGS/cascade-client.log" 2>&1 &)
	fi
fi

say "done — run ./fleetcom-doctor.sh to verify. AB: https://localhost:9002  Cascade: http://localhost:8088"
