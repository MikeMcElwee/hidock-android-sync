#!/data/data/com.termux/files/usr/bin/bash
# JobScheduler entrypoint. Installed by setup-jobscheduler.sh as job id 834001.
# Logs a JOB_FIRE line, appends a world-readable tick for adb cold-boot prove,
# then runs the existing ingest wrapper.
set -u

HERE="$(dirname "$(readlink -f "$0")")"
HIDOCK_JOB_ID=834001
TICK_FILE="${JOB_TICK_FILE:-/sdcard/Download/hidock_job_ticks.txt}"
# So run_sync.sh appends USB_PERM_DENIED to the same adb-readable tick file.
export JOB_TICK_FILE="$TICK_FILE"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
JOB_LINE="JOB_FIRE ts=${STAMP} job-id=${HIDOCK_JOB_ID} pid=$$ boot_id=${BOOT_ID}"

echo "$JOB_LINE"

# World-readable tick so a PC can adb-prove a post-reboot fire without opening Termux.
mkdir -p "$(dirname "$TICK_FILE")" 2>/dev/null || true
echo "$JOB_LINE" >> "$TICK_FILE" 2>/dev/null || echo "JOB_FIRE tick file not writable: $TICK_FILE" >&2

CONF="$HOME/.config/hidock-sync/config"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    if [ -n "${LOG_DIR:-}" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        echo "$JOB_LINE" >> "$LOG_DIR/cron_ticks.log" 2>/dev/null || true
    fi
fi

if [ ! -f "$HERE/run_sync.sh" ]; then
    echo "run_sync.sh missing next to $0" >&2
    exit 2
fi
# Exec via bash so the Termux shebang on run_sync.sh is not required
# (offline tests, and JobScheduler already launched us under Termux bash).
BASH_BIN="/data/data/com.termux/files/usr/bin/bash"
if [ ! -x "$BASH_BIN" ]; then
    BASH_BIN="$(command -v bash || true)"
fi
if [ -z "$BASH_BIN" ]; then
    echo "bash not found; cannot exec run_sync.sh" >&2
    exit 2
fi
exec "$BASH_BIN" "$HERE/run_sync.sh" "$@"
