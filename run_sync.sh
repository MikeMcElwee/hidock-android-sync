#!/data/data/com.termux/files/usr/bin/bash
# Cron-friendly wrapper that:
#   1) discovers the HiDock USB device path
#   2) on first ever invocation with `request`, asks Android for permission
#   3) on every other invocation, runs hidock_sync.py inside `termux-usb -e`
set -u

HERE="$(dirname "$(readlink -f "$0")")"
CONF="$HOME/.config/hidock-sync/config"
[ -f "$CONF" ] || { echo "config missing at $CONF — run setup.sh first"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
mkdir -p "$LOG_DIR"
TICK_LOG="$LOG_DIR/cron_ticks.log"
exec >>"$TICK_LOG" 2>&1
echo
echo "=== $(date) PID=$$ args=$* ==="

DEV="$(termux-usb -l 2>&1 | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' | head -1)"
if [ -z "$DEV" ]; then
    echo "no USB device attached, skipping"
    exit 0
fi
echo "device: $DEV"

if [ "${1:-}" = "request" ]; then
    echo "requesting Android USB permission (user must tap OK on the dialog)"
    termux-usb -r "$DEV"
    echo "permission request returned $?"
    exit 0
fi

termux-usb -e "python $HERE/hidock_sync.py $*" "$DEV"
RC=$?
echo "termux-usb returned $RC"
echo "--- last 20 lines of $LOG_DIR/sync.log ---"
tail -20 "$LOG_DIR/sync.log" 2>/dev/null || true
echo "=== END $(date) ==="
