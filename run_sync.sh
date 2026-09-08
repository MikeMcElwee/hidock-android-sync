#!/data/data/com.termux/files/usr/bin/bash
# Scheduler-friendly wrapper that:
#   1) discovers the HiDock USB device path
#   2) on first ever invocation with `request`, asks Android for permission
#   3) on every other invocation, runs hidock_sync.py inside `termux-usb -e`
#   4) if -e fails with permission denied (typical after cold boot), auto-runs
#      `termux-usb -r` once and retries -e. Still denied → USB_PERM_DENIED +
#      notification. This is NOT an OS-level persist.
set -u

HERE="$(dirname "$(readlink -f "$0")")"
CONF="$HOME/.config/hidock-sync/config"
[ -f "$CONF" ] || { echo "config missing at $CONF — run setup.sh first"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
mkdir -p "$LOG_DIR"
TICK_LOG="$LOG_DIR/cron_ticks.log"
TICK_FILE="${JOB_TICK_FILE:-/sdcard/Download/hidock_job_ticks.txt}"
exec >>"$TICK_LOG" 2>&1
echo
echo "=== $(date) PID=$$ args=$* ==="

DEV="$(termux-usb -l 2>&1 | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' | head -1)"
if [ -z "$DEV" ]; then
    echo "no USB device attached, skipping"
    exit 0
fi
echo "device: $DEV"

notify_usb_ok() {
    if ! command -v termux-notification >/dev/null 2>&1; then
        echo "termux-notification not on PATH; skip USB OK notify"
        return 0
    fi
    termux-notification \
        --id hidock-usb-perm \
        --title "HiDock needs USB OK" \
        --content "Mike: tap OK on the Android USB dialog so Termux:API can open the HiDock P1 mini. This is expected once after a reboot. JobScheduler is fine — Android wiped the grant." \
        --priority high \
        2>/dev/null || echo "termux-notification failed"
}

write_usb_perm_denied() {
    STAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
    BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    LINE="USB_PERM_DENIED ts=${STAMP} device=${DEV} pid=$$ boot_id=${BOOT_ID} — tap OK on the USB dialog (expected once after reboot)"
    echo "$LINE"
    mkdir -p "$(dirname "$TICK_FILE")" 2>/dev/null || true
    echo "$LINE" >> "$TICK_FILE" 2>/dev/null || echo "USB_PERM_DENIED tick file not writable: $TICK_FILE"
}

USB_CAPTURE=""
usb_open_denied() {
    [ -n "$USB_CAPTURE" ] && [ -f "$USB_CAPTURE" ] && grep -qi 'permission denied' "$USB_CAPTURE"
}

run_termux_usb_open() {
    if [ -z "$USB_CAPTURE" ]; then
        USB_CAPTURE="$(mktemp "${TMPDIR:-/tmp}/hidock-usb.XXXXXX")" || USB_CAPTURE="$LOG_DIR/usb_open.out"
    fi
    # Capture then replay so we can detect "Permission denied" without a pipe
    # swallowing termux-usb's exit code. hidock_sync.py logs progress to sync.log.
    termux-usb -e "python $HERE/hidock_sync.py $*" "$DEV" >"$USB_CAPTURE" 2>&1
    local rc=$?
    cat "$USB_CAPTURE"
    return "$rc"
}

if [ "${1:-}" = "request" ]; then
    echo "requesting Android USB permission (user must tap OK on the dialog)"
    termux-usb -r "$DEV"
    echo "permission request returned $?"
    exit 0
fi

run_termux_usb_open "$@"
RC=$?
if [ "$RC" -ne 0 ] && usb_open_denied; then
    echo "termux-usb open denied; auto-requesting USB permission (tap OK if a dialog appears)"
    notify_usb_ok
    termux-usb -r "$DEV"
    echo "termux-usb -r returned $?"
    run_termux_usb_open "$@"
    RC=$?
    if [ "$RC" -ne 0 ] && usb_open_denied; then
        echo "termux-usb still denied after one auto-request"
        write_usb_perm_denied
        notify_usb_ok
        echo "termux-usb returned $RC"
        echo "=== END $(date) ==="
        rm -f "$USB_CAPTURE"
        exit 1
    fi
fi
echo "termux-usb returned $RC"
echo "--- last 20 lines of $LOG_DIR/sync.log ---"
tail -20 "$LOG_DIR/sync.log" 2>/dev/null || true
echo "=== END $(date) ==="
rm -f "$USB_CAPTURE"
