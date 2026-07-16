#!/bin/bash
# FLEETCOM: full bounce of everything — Midship included — then start fresh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/stop-all.sh" --midship
"$HERE/start-all.sh"
