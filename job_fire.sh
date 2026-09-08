#!/data/data/com.termux/files/usr/bin/bash
# JobScheduler entrypoint for hidock-android-sync (job id 834001).
# Registered by setup-jobscheduler.sh; logs a JOB_FIRE tick then execs run_sync.sh.
set -euo pipefail

export PATH="/data/data/com.termux/files/usr/bin:${PATH:-}"
export HOME="${HOME:-/data/data/com.termux/files/home}"

HERE="$(dirname "$(readlink -f "$0")")"
CONF="$HOME/.config/hidock-sync/config"
[ -f "$CONF" ] || { echo "config missing at $CONF — run setup.sh first" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
mkdir -p "$LOG_DIR"

# Keep cron_ticks.log so existing tail/watchers do not have to change.
echo "JOB_FIRE $(date -Is) job=834001" >>"$LOG_DIR/cron_ticks.log"

cd "$HERE"
exec "$HERE/run_sync.sh" "$@"
