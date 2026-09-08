#!/data/data/com.termux/files/usr/bin/bash
# Register a persisted Android JobScheduler job via termux-job-scheduler.
# Replaces cron/crond. Idempotent.
#
# Job id 834001 is fixed for this repo (cancel + re-register on every run).
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
CONF="$HOME/.config/hidock-sync/config"
[ -f "$CONF" ] || { echo "config missing at $CONF — run setup.sh first"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"

# Prefer JOB_INTERVAL_MIN, then the old CRON_INTERVAL_MIN alias, then 30.
INTERVAL="${JOB_INTERVAL_MIN:-${CRON_INTERVAL_MIN:-30}}"
case "$INTERVAL" in
    ''|*[!0-9]*)
        echo "JOB_INTERVAL_MIN/CRON_INTERVAL_MIN must be a positive integer (got: $INTERVAL)"
        exit 2
        ;;
esac
PERIOD_MS=$((INTERVAL * 60 * 1000))
# Android JobScheduler (N+) typically enforces a 15-minute minimum period.
MIN_PERIOD_MS=900000
if [ "$PERIOD_MS" -lt "$MIN_PERIOD_MS" ]; then
    echo "WARN: JobScheduler minimum period is 15 min; clamping ${PERIOD_MS}ms -> ${MIN_PERIOD_MS}ms (requested ${INTERVAL} min)"
    PERIOD_MS="$MIN_PERIOD_MS"
fi

JOB_ID=834001
WRAPPER="$HERE/job_fire.sh"
LOG_DIR="${LOG_DIR:-$HOME/.config/hidock-sync}"
mkdir -p "$LOG_DIR"

command -v termux-job-scheduler >/dev/null || {
    echo "termux-job-scheduler missing — pkg install termux-api (and install the Termux:API Android app)"
    exit 3
}

# Absolute wrapper: PATH + HOME, JOB_FIRE tick, then exec run_sync.sh.
cat >"$WRAPPER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# JobScheduler entrypoint for hidock-android-sync (job id ${JOB_ID}).
# Generated/refreshed by setup-jobscheduler.sh; do not start crond from here.
set -euo pipefail

export PATH="/data/data/com.termux/files/usr/bin:\${PATH:-}"
export HOME="\${HOME:-/data/data/com.termux/files/home}"

HERE="$HERE"
CONF="\$HOME/.config/hidock-sync/config"
[ -f "\$CONF" ] || { echo "config missing at \$CONF — run setup.sh first" >&2; exit 2; }
# shellcheck source=/dev/null
. "\$CONF"
mkdir -p "\$LOG_DIR"

# Keep cron_ticks.log so existing tail/watchers do not have to change.
echo "JOB_FIRE \$(date -Is) job=${JOB_ID}" >>"\$LOG_DIR/cron_ticks.log"

cd "\$HERE"
exec "\$HERE/run_sync.sh" "\$@"
EOF
chmod +x "$WRAPPER"

# Cancel existing job 834001 first (idempotent re-register). --job-id also overwrites.
if termux-job-scheduler --cancel --job-id "$JOB_ID" >/dev/null 2>&1; then
    echo "cancelled existing job $JOB_ID"
else
    echo "no existing job $JOB_ID to cancel (ok)"
fi

echo "registering job $JOB_ID period-ms=$PERIOD_MS script=$WRAPPER"
termux-job-scheduler \
    --job-id "$JOB_ID" \
    --period-ms "$PERIOD_MS" \
    --persisted true \
    --battery-not-low false \
    --network any \
    -s "$WRAPPER"

# Cron is retired — disable crontab and stop crond if it is running.
if crontab -l >/dev/null 2>&1; then
    crontab -r || true
    echo "crontab cleared"
fi
if pgrep -x crond >/dev/null 2>&1; then
    pkill -x crond || true
    echo "stopped crond"
fi
echo "NOTE: cron/crond is retired. Schedule is Android JobScheduler job $JOB_ID (persisted)."

# Drop the old boot script that started crond (migration from setup-cron.sh).
if [ -f "$HOME/.termux/boot/start-crond" ]; then
    rm -f "$HOME/.termux/boot/start-crond"
    echo "removed deprecated ~/.termux/boot/start-crond"
fi

# Optional Termux:Boot re-assert only — does NOT start crond.
# JobScheduler --persisted true is the primary post-reboot path.
mkdir -p "$HOME/.termux/boot"
cat >"$HOME/.termux/boot/reassert-hidock-job" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Optional cold-boot re-assert of JobScheduler job ${JOB_ID}.
# Not the schedule itself — --persisted true survives reboot without this.
exec /data/data/com.termux/files/usr/bin/bash $HERE/setup-jobscheduler.sh
EOF
chmod +x "$HOME/.termux/boot/reassert-hidock-job"
echo "optional boot re-assert: $HOME/.termux/boot/reassert-hidock-job"

cat <<EOM

Done. JobScheduler job ${JOB_ID}: every ${INTERVAL} min (${PERIOD_MS} ms), persisted.

Register command used:
  termux-job-scheduler --job-id ${JOB_ID} --period-ms ${PERIOD_MS} --persisted true --battery-not-low false --network any -s ${WRAPPER}

Verify:
  termux-job-scheduler -p
  tail -f ${LOG_DIR}/cron_ticks.log
  # A healthy fire line looks like: JOB_FIRE 2026-09-08T12:00:00+00:00 job=834001

Reminder:
  * Settings → Apps → Termux and Termux:API → Battery → Unrestricted.
  * Termux:Boot is optional (re-assert only). If you install it, tap its icon once
    so it can register BOOT_COMPLETED. Do not rely on it — or on crond — for the schedule.
EOM
