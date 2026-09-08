#!/data/data/com.termux/files/usr/bin/bash
# Install the supported Android JobScheduler schedule. Idempotent.
#
# Replaces Termux:Boot + crond. Persisted jobs are owned by Termux:API
# (com.termux.api) and survive reboot without opening Termux.
# setup-cron.sh is kept only as a deprecated fallback.
set -euo pipefail

HIDOCK_JOB_ID=834001
ANDROID_MIN_PERIOD_MIN=15

HERE="$(dirname "$(readlink -f "$0")")"
CONF="$HOME/.config/hidock-sync/config"
[ -f "$CONF" ] || { echo "config missing at $CONF — run setup.sh first"; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

WRAPPER="$(readlink -f "$HERE/job_fire.sh")"
[ -f "$WRAPPER" ] || { echo "wrapper missing at $WRAPPER"; exit 2; }
chmod +x "$WRAPPER" "$HERE/run_sync.sh" 2>/dev/null || true

if command -v termux-job-scheduler >/dev/null 2>&1; then
    TJS="$(command -v termux-job-scheduler)"
elif [ -x /data/data/com.termux/files/usr/bin/termux-job-scheduler ]; then
    TJS=/data/data/com.termux/files/usr/bin/termux-job-scheduler
else
    echo "termux-job-scheduler not found."
    echo "  pkg install termux-api"
    echo "  and install the Termux:API Android app (same source as Termux)."
    exit 2
fi

if [ "${1:-}" = "--cancel" ]; then
    echo "Cancelling JobScheduler job ${HIDOCK_JOB_ID}"
    "$TJS" --cancel --job-id "$HIDOCK_JOB_ID"
    exit 0
fi

INTERVAL="${CRON_INTERVAL_MIN:-30}"
if ! [ "$INTERVAL" -ge 1 ] 2>/dev/null; then
    echo "CRON_INTERVAL_MIN must be a positive integer (got: ${INTERVAL})"
    exit 2
fi
if [ "$INTERVAL" -lt "$ANDROID_MIN_PERIOD_MIN" ]; then
    echo "note: CRON_INTERVAL_MIN=${INTERVAL} is below Android's JobScheduler minimum of ${ANDROID_MIN_PERIOD_MIN} min; clamping"
    INTERVAL="$ANDROID_MIN_PERIOD_MIN"
fi
PERIOD_MS=$((INTERVAL * 60 * 1000))

# 1) Schedule (same --job-id overwrites any previous registration).
echo "Scheduling persisted JobScheduler job ${HIDOCK_JOB_ID} every ${INTERVAL} min (${PERIOD_MS} ms)"
"$TJS" \
    --job-id "$HIDOCK_JOB_ID" \
    --period-ms "$PERIOD_MS" \
    --persisted true \
    --battery-not-low false \
    --network any \
    -s "$WRAPPER"

echo
echo "Pending jobs:"
"$TJS" -p || true

# 2) Retire cron so crond cannot race the JobScheduler path.
if command -v crontab >/dev/null 2>&1; then
    CURRENT="$(crontab -l 2>/dev/null || true)"
    if [ -n "$CURRENT" ]; then
        FILTERED="$(printf '%s\n' "$CURRENT" | grep -v -E 'hidock-android-sync|run_sync\.sh' || true)"
        if [ -n "$(printf '%s\n' "$FILTERED" | grep -v -E '^[[:space:]]*(#|$)' || true)" ]; then
            printf '%s\n' "$FILTERED" | crontab -
            echo "crontab: removed hidock-android-sync lines (left other entries)"
        else
            crontab -r 2>/dev/null || true
            echo "crontab: cleared"
        fi
    else
        echo "crontab: none"
    fi
else
    echo "crontab: not installed (ok — cron is not required)"
fi
rm -f "$HOME/.config/cron/crontab"

if command -v pkill >/dev/null 2>&1; then
    pkill -x crond 2>/dev/null || true
    echo "crond: stopped (if it was running)"
fi

# 3) Replace the old Termux:Boot crond starter with a thin re-assert.
# Persisted jobs should already survive reboot; Boot is optional insurance only.
mkdir -p "$HOME/.termux/boot"
BOOT="$HOME/.termux/boot/start-crond"
cat > "$BOOT" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# Optional Termux:Boot insurance only.
# Android JobScheduler persisted jobs (com.termux.api, job ${HIDOCK_JOB_ID})
# should already survive reboot without opening Termux or Termux:Boot.
# This script only re-registers the same job if something dropped it.
"${TJS}" \\
    --job-id ${HIDOCK_JOB_ID} \\
    --period-ms ${PERIOD_MS} \\
    --persisted true \\
    --battery-not-low false \\
    --network any \\
    -s "${WRAPPER}" \\
    >/dev/null 2>&1 || true
EOF
chmod +x "$BOOT"
echo "boot insurance (optional): $BOOT"

cat <<EOM

Done. Supported schedule: JobScheduler job ${HIDOCK_JOB_ID}, every ${INTERVAL} min, persisted.

  List:   termux-job-scheduler -p
  Cancel: termux-job-scheduler --cancel --job-id ${HIDOCK_JOB_ID}
          (or: bash ${HERE}/setup-jobscheduler.sh --cancel)

Ticks:
  ${LOG_DIR}/cron_ticks.log
  /sdcard/Download/hidock_job_ticks.txt   # adb-readable cold-boot prove

Reminder — JobScheduler is owned by Termux:API, not by a Termux session:
  * Settings → Apps → Termux and Termux:API → Battery → Unrestricted.
  * Termux:Boot is optional insurance only (this setup wrote a re-assert
    script; persisted jobs should fire after reboot without opening Termux).
  * Cold-boot prove: reboot without opening Termux, then check
    /sdcard/Download/hidock_job_ticks.txt for a new JOB_FIRE line and/or
    \`adb shell dumpsys jobscheduler\` for com.termux.api job ${HIDOCK_JOB_ID}.
EOM
