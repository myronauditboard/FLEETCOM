#!/bin/bash
# FLEETCOM onboarding: apply all port-deconfliction + SSO config for
# running Midship, Cascade, and AuditBoard side-by-side. Idempotent — safe to
# re-run any time (e.g. after `bin/generate-config` regenerates .envrc, or
# after a machine-learning pull reverts its compose override).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/paths.sh"
MARKER="FLEETCOM"
PG_CONF=/opt/homebrew/var/postgresql@17/postgresql.conf
REDIS_CONF=/opt/homebrew/etc/redis.conf

say() { printf '\033[36m[onboard]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[onboard] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- repo locations ----------------------------------------------------------
# Prompt once (Enter accepts the default), persist to gitignored local.conf.
# Re-run with --reconfigure to change. Without a TTY, defaults are used as-is.
prompt_path() { # varname, description
	local var=$1 desc=$2 val
	read -r -p "[onboard] $desc [${!var}]: " val || true
	val="${val:-${!var}}"
	val="${val/#\~/$HOME}"
	[ -d "$val" ] || say "note: $val does not exist (yet)"
	printf -v "$var" '%s' "$val"
}
if [ ! -f "$HERE/local.conf" ] || [ "${1:-}" = "--reconfigure" ]; then
	if [ -t 0 ]; then
		say "where do your repos live? (Enter to accept each default)"
		prompt_path MIDSHIP_DIR     "midship repos parent dir"
		prompt_path CASCADE_DIR     "cascade repo"
		prompt_path AB_BACKEND_DIR  "auditboard-backend repo"
		prompt_path AB_FRONTEND_DIR "auditboard-frontend repo"
		prompt_path AB_DEVENV_DIR   "auditboard-dev-env repo"
		ML_DIR="$AB_DEVENV_DIR/machine-learning"
	else
		say "no TTY — using default/current repo paths"
	fi
	cat > "$HERE/local.conf" <<EOF
# FLEETCOM per-machine repo locations (gitignored).
# Regenerate with: ./onboard.sh --reconfigure
MIDSHIP_DIR="$MIDSHIP_DIR"
CASCADE_DIR="$CASCADE_DIR"
AB_BACKEND_DIR="$AB_BACKEND_DIR"
AB_FRONTEND_DIR="$AB_FRONTEND_DIR"
AB_DEVENV_DIR="$AB_DEVENV_DIR"
EOF
	say "repo paths saved to local.conf"
fi
DEVENV="$AB_DEVENV_DIR"
CASCADE="$CASCADE_DIR"
ML="$ML_DIR"

# --- prerequisites ---------------------------------------------------------
for cmd in brew docker direnv gh abc lsof; do
	command -v "$cmd" >/dev/null || die "missing prerequisite: $cmd"
done
docker compose version --short | awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 24)) }' \
	|| die "docker compose >= 2.24 required (for !override port merging)"
[ -d "$DEVENV" ] || die "$DEVENV not found — run 'abc init' first"
[ -d "$CASCADE" ] || die "$CASCADE not found — clone soxhub/cascade"
[ -f "$DEVENV/.envrc" ] || die "$DEVENV/.envrc missing — run CREATE_ENVRC=true bin/generate-config"

# --- 0. Docker Desktop resources: >=12G memory, >=120G disk -----------------
# Three stacks need ~50GB of images plus working space, and the AB + ML
# containers are memory-hungry. Requires a Docker Desktop restart to apply.
DOCKER_SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
WANT_MEM_MIB=12288 WANT_DISK_MIB=122880
if [ -f "$DOCKER_SETTINGS" ] && ! python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s.get("MemoryMiB",0)>=int(sys.argv[2]) and s.get("DiskSizeMiB",0)>=int(sys.argv[3]) else 1)' "$DOCKER_SETTINGS" "$WANT_MEM_MIB" "$WANT_DISK_MIB"; then
	say "Docker Desktop is below ${WANT_MEM_MIB}MiB memory / ${WANT_DISK_MIB}MiB disk"
	read -r -p "[onboard] Restart Docker Desktop now to apply? ALL running containers stop; re-run start-all.sh after. [y/N] " yn
	if [[ "$yn" =~ ^[Yy]$ ]]; then
		osascript -e 'quit app "Docker Desktop"' 2>/dev/null || true
		sleep 10
		python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["MemoryMiB"]=max(s.get("MemoryMiB",0),int(sys.argv[2])); s["DiskSizeMiB"]=max(s.get("DiskSizeMiB",0),int(sys.argv[3])); json.dump(s,open(p,"w"),indent=1)' "$DOCKER_SETTINGS" "$WANT_MEM_MIB" "$WANT_DISK_MIB"
		open -a "Docker Desktop"
		say "waiting for docker engine..."
		until docker info >/dev/null 2>&1; do sleep 3; done
		say "docker is back — remember: midship compose services do NOT auto-restart (run start-all.sh)"
	else
		say "skipped — set Memory >=12GB and Disk >=120GB in Docker Desktop > Settings > Resources"
	fi
fi

# --- 1. Homebrew Postgres -> 5433 -----------------------------------------
if grep -qE '^port = 5433' "$PG_CONF"; then
	say "postgres already on 5433"
else
	grep -qE '^#?port = ' "$PG_CONF" || die "no port line found in $PG_CONF"
	sed -i '' -E "s|^#?port = [0-9]+|port = 5433|" "$PG_CONF"
	say "postgres port set to 5433 (was 5432 default)"
fi
brew services start postgresql@17 >/dev/null 2>&1 || true
launchctl kickstart gui/$(id -u)/homebrew.mxcl.postgresql@17 2>/dev/null || true

# --- 2. Homebrew Redis -> 6382 (6380/6381 belong to ML redisearch) ---------
if grep -qE '^port 6382' "$REDIS_CONF"; then
	say "redis already on 6382"
else
	sed -i '' -E "s|^port [0-9]+|port 6382|" "$REDIS_CONF"
	say "redis port set to 6382"
fi
brew services start redis >/dev/null 2>&1 || true
launchctl kickstart -k gui/$(id -u)/homebrew.mxcl.redis 2>/dev/null || true

# --- 3. dev-env .envrc override block --------------------------------------
if grep -q "$MARKER" "$DEVENV/.envrc"; then
	say ".envrc override block already present"
	SECRET=$(grep "^export CASCADE_JWT_SECRET=" "$DEVENV/.envrc" | cut -d"'" -f2)
else
	SECRET=$(openssl rand -hex 32)
	cat >> "$DEVENV/.envrc" <<EOF

# ============================================================================
# $MARKER overrides — keep this block LAST (last export wins).
# Re-run FLEETCOM/onboard.sh after bin/generate-config regenerates
# this file. Deconflicts ports with the Midship stack (which holds 5432,
# 6379, 8000, 8080) and wires local Cascade SSO.
# ============================================================================
export DATABASE_URL=postgres://\$DB_USER@localhost:5433/\$DB_NAME
export REDIS_URL='redis://localhost:6382'
export DOCKER_REDIS_URL='redis://host.docker.internal:6382'
export PERMISSIONS_DATABASE_URL='postgres://postgres@host.docker.internal:5433/demo_data'
export CONDUCTOR_SERVER_URL='http://localhost:18080/api'
export AB_MLSERVICE_LOCAL_SERVICE_PORT='8004'
export CASCADE_JWT_SECRET='${SECRET}'
EOF
	say ".envrc override block appended (new shared JWT secret generated)"
fi
(cd "$DEVENV" && direnv allow)

# --- 4. Cascade docker-compose.override.yml ---------------------------------
cp "$(dirname "$0")/cascade-compose.override.yml" "$CASCADE/docker-compose.override.yml"
grep -qx "docker-compose.override.yml" "$CASCADE/.git/info/exclude" 2>/dev/null \
	|| echo "docker-compose.override.yml" >> "$CASCADE/.git/info/exclude"
say "cascade compose override installed (redis 63790, debugpy 15678+, local image tag)"

# --- 5. machine-learning override: ML local -> 8004 -------------------------
if [ -d "$ML" ]; then
	if grep -q '"8004:8000"' "$ML/docker-compose.override.yml" 2>/dev/null; then
		say "ML port override already present"
	elif grep -q "ab_mlservice_local:" "$ML/docker-compose.override.yml" 2>/dev/null; then
		# insert ports override under the service key (tracked file — shows as modified)
		awk '1; /^  ab_mlservice_local:$/ {
			print "    # FLEETCOM: host port moves off 8000 (held by Midship FastAPI)."
			print "    ports: !override"
			print "      - \"8004:8000\""
		}' "$ML/docker-compose.override.yml" > "$ML/docker-compose.override.yml.tmp" \
			&& mv "$ML/docker-compose.override.yml.tmp" "$ML/docker-compose.override.yml"
		say "ML port override inserted into existing docker-compose.override.yml"
	else
		printf 'services:\n  ab_mlservice_local:\n    # FLEETCOM: host port moves off 8000.\n    ports: !override\n      - "8004:8000"\n' \
			> "$ML/docker-compose.override.yml"
		say "ML docker-compose.override.yml created"
	fi
else
	say "machine-learning repo not found (start-background clones it) — re-run onboard.sh after first start"
fi

# --- 6. Cascade .env SSO block ----------------------------------------------
[ -f "$CASCADE/.env" ] || { [ -f "$CASCADE/.env.example" ] && cp "$CASCADE/.env.example" "$CASCADE/.env" && say "cascade .env created from .env.example — fill in SECRET_KEY/SALT_KEY/LaunchDarkly keys"; }
# dotenv semantics: the last occurrence of a key wins, so appending overrides.
for key in SECRET_KEY SALT_KEY; do
	if ! grep -qE "^${key}=.+" "$CASCADE/.env"; then
		printf '%s=%s\n' "$key" "$(openssl rand -hex 32)" >> "$CASCADE/.env"
		say "cascade .env: generated $key"
	fi
done
# LaunchDarkly keys are real secrets each dev must supply: prompted here and
# written ONLY to cascade/.env (gitignored in cascade). Get them from 1Password.
# dotenv semantics: last occurrence wins, so appending overrides empty values.
if ! { grep -qE '^LAUNCH_DARKLY_SDK_KEY=.+' "$CASCADE/.env" && grep -qE '^LAUNCH_DARKLY_CLIENT_ID=.+' "$CASCADE/.env"; }; then
	if [ -t 0 ]; then
		say "LaunchDarkly keys for cascade — 1Password > QE Team Vault > Cascade base env file (stored only in cascade/.env; Enter to skip)"
		read -r -p "[onboard]   LAUNCH_DARKLY_SDK_KEY (sdk-...): " LD_SDK || true
		read -r -p "[onboard]   LAUNCH_DARKLY_CLIENT_ID (hex): " LD_CID || true
		if [ -n "${LD_SDK:-}" ] && [ -n "${LD_CID:-}" ]; then
			printf '\nLAUNCH_DARKLY_SDK_KEY=%s\nLAUNCH_DARKLY_CLIENT_ID=%s\n' "$LD_SDK" "$LD_CID" >> "$CASCADE/.env"
			say "LaunchDarkly keys written to cascade/.env"
		else
			say "WARNING: skipped — the cascade client will crash fetching flags (and land on /404) until both are set in cascade/.env; re-run onboard.sh to be prompted again"
		fi
	else
		say "WARNING: LAUNCH_DARKLY_SDK_KEY / LAUNCH_DARKLY_CLIENT_ID missing from cascade/.env and no TTY to prompt — set them manually or re-run onboard.sh interactively"
	fi
fi
if grep -q "$MARKER" "$CASCADE/.env"; then
	say "cascade .env SSO block already present"
else
	cat >> "$CASCADE/.env" <<EOF

# ==== $MARKER SSO wiring (matches CASCADE_JWT_SECRET in auditboard-dev-env/.envrc)
JWT_AUTH_SHARED_SECRET=${SECRET}
JWT_AUTH_ISSUER=auditboard
AB_DOMAINS=localhost:9002
AB_LOGIN_URL=https://localhost:9002/login
EOF
	say "cascade .env SSO block appended"
fi

# --- 7. AB database seed (SQL dump import — DESTRUCTIVE, always confirmed) ---
# reset-db terminates active connections itself, so servers can stay up.
# Note workspace precedence is .dump > .sql.zip > .sql regardless of age; an
# explicitly entered path bypasses that via DATA_DUMP_FILE.
DEFAULT_DUMP=$(ls -1 "$DEVENV/workspace" 2>/dev/null | grep -E '\.dump$' | tail -n 1)
[ -z "$DEFAULT_DUMP" ] && DEFAULT_DUMP=$(ls -1 "$DEVENV/workspace" 2>/dev/null | grep -E '\.sql(\.zip)?$' | tail -n 1)
if [ -t 0 ]; then
	say "AB database seed — importing a dump DROPS and replaces the ENTIRE demo_data DB (all local AB data)"
	while :; do
		read -r -p "[onboard] SQL dump to import (Enter = workspace default: ${DEFAULT_DUMP:-none found}): " DUMP_PATH || true
		DUMP_PATH="${DUMP_PATH/#\~/$HOME}"
		[ -z "$DUMP_PATH" ] && break
		if [ -f "$DUMP_PATH" ]; then
			# Keep a copy in the team-standard location. Do NOT rename: the
			# extension selects the import tool (.dump -> pg_restore, else psql).
			WS_COPY="$DEVENV/workspace/$(basename "$DUMP_PATH")"
			mkdir -p "$DEVENV/workspace"
			if [ ! -f "$WS_COPY" ]; then
				cp "$DUMP_PATH" "$WS_COPY"
				say "copied $(basename "$DUMP_PATH") into $DEVENV/workspace/"
				case "$DUMP_PATH" in *.dump) ;; *)
					say "note: workspace *default* resolution prefers .dump files over .sql — enter this path explicitly on future runs, or clear old .dump files from workspace/"
				;; esac
			fi
			DUMP_PATH="$WS_COPY"
			break
		fi
		say "not found: $DUMP_PATH — check for typos and try again, or press Enter to use the workspace default"
	done
	if [ -z "$DUMP_PATH" ] && [ -z "$DEFAULT_DUMP" ]; then
		say "no dump available — ask a teammate for the current platform dataset dump, then re-run onboard.sh or: abc run reset-db"
	else
		SEED_NAME=$([ -n "$DUMP_PATH" ] && basename "$DUMP_PATH" || echo "$DEFAULT_DUMP")
		read -r -p "[onboard] Type 'reset' to DROP demo_data and import $SEED_NAME now (anything else skips): " CONFIRM || true
		if [ "$CONFIRM" = "reset" ]; then
			if [ -n "$DUMP_PATH" ]; then
				(cd "$DEVENV" && DATA_DUMP_FILE="$DUMP_PATH" direnv exec . abc run reset-db -- -y)
			else
				(cd "$DEVENV" && direnv exec . abc run reset-db -- -y)
			fi
			say "AB database seeded from $SEED_NAME (login: ops@soxhub.com / password)"
		else
			say "seed skipped — run later via onboard.sh or: abc run reset-db (see README 'Database seeding')"
		fi
	fi
elif [ -z "$DEFAULT_DUMP" ]; then
	say "WARNING: no SQL data dump in auditboard-dev-env/workspace/ and no TTY to prompt — ask a teammate for the current platform dataset dump, then run: abc run reset-db"
fi

say "done. Next: ./start-all.sh && ./doctor.sh — see README.md"
