#!/usr/bin/env bash
# Offline tests for USB permission auto-request + notify (no Termux / USB).
# Run: bash test_usb_perm.sh
set -euo pipefail

ROOT="$(dirname "$(readlink -f "$0")")"
FAILS=0
assert() {
    if ! eval "$1"; then
        echo "FAIL: $2"
        echo "      cond: $1"
        FAILS=$((FAILS + 1))
    else
        echo "ok: $2"
    fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

HOME_DIR="$WORKDIR/home"
BIN="$WORKDIR/bin"
STATE="$WORKDIR/state"
mkdir -p "$HOME_DIR/.config/hidock-sync" "$BIN" "$STATE"

cat > "$HOME_DIR/.config/hidock-sync/config" <<EOF
LOG_DIR=$HOME_DIR/.config/hidock-sync
EOF

# termux-usb mock. Behavior is selected via STATE/usb_mode:
#   ok          — -e always succeeds
#   deny_once   — first -e Permission denied; later -e succeeds (after -r)
#   deny_always — every -e Permission denied
#   busy        — -e fails with a non-permission error
cat > "$BIN/termux-usb" <<EOF
#!/usr/bin/env bash
echo "termux-usb \$*" >> "$STATE/usb.log"
printf '%s\n' "\$@" >> "$STATE/usb.args"
MODE="\$(cat "$STATE/usb_mode" 2>/dev/null || echo ok)"
case "\${1:-}" in
    -l)
        echo "/dev/bus/usb/001/002"
        exit 0
        ;;
    -r)
        echo 1 >> "$STATE/usb_r.count"
        echo "permission request shown"
        exit 0
        ;;
    -e)
        echo 1 >> "$STATE/usb_e.count"
        E_COUNT="\$(wc -l < "$STATE/usb_e.count")"
        if [ "\$MODE" = "ok" ]; then
            echo "OPEN_OK"
            exit 0
        fi
        if [ "\$MODE" = "busy" ]; then
            echo "device busy"
            exit 7
        fi
        if [ "\$MODE" = "deny_once" ] && [ "\$E_COUNT" -ge 2 ]; then
            echo "OPEN_OK"
            exit 0
        fi
        echo "Permission denied"
        exit 1
        ;;
    *)
        echo "unexpected termux-usb args: \$*" >&2
        exit 99
        ;;
esac
EOF
chmod +x "$BIN/termux-usb"

cat > "$BIN/termux-notification" <<EOF
#!/usr/bin/env bash
echo "termux-notification \$*" >> "$STATE/notify.log"
printf '%s\n' "\$@" > "$STATE/notify.last_args"
exit 0
EOF
chmod +x "$BIN/termux-notification"

run_sync() {
    : > "$STATE/usb.log"
    : > "$STATE/usb.args"
    : > "$STATE/notify.log"
    rm -f "$STATE/usb_e.count" "$STATE/usb_r.count" "$STATE/notify.last_args"
    rm -f "$HOME_DIR/.config/hidock-sync/cron_ticks.log"
    JOB_TICK_FILE="$TICK" HOME="$HOME_DIR" PATH="$BIN:$PATH" \
        bash "$ROOT/run_sync.sh" "$@"
}

TICK="$WORKDIR/ticks.txt"
: > "$TICK"

echo "== first open succeeds: no auto-request, no notify"
echo ok > "$STATE/usb_mode"
RC=0
run_sync --dry-run || RC=$?
assert "[ \"$RC\" -eq 0 ]" "success path exits 0"
assert "[ \"\$(wc -l < \"$STATE/usb_e.count\")\" -eq 1 ]" "termux-usb -e once"
assert "[ ! -f \"$STATE/usb_r.count\" ]" "termux-usb -r not called"
assert "! grep -q USB_PERM_DENIED \"$TICK\"" "no USB_PERM_DENIED on success"
assert "[ ! -s \"$STATE/notify.log\" ]" "no notification on success"
assert "grep -q 'termux-usb returned 0' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "tick log records success"

echo
echo "== permission denied then grant on retry"
echo deny_once > "$STATE/usb_mode"
: > "$TICK"
RC=0
run_sync --limit 1 || RC=$?
assert "[ \"$RC\" -eq 0 ]" "denied-then-grant exits 0"
assert "[ \"\$(wc -l < \"$STATE/usb_e.count\")\" -eq 2 ]" "termux-usb -e retried once"
assert "[ \"\$(wc -l < \"$STATE/usb_r.count\")\" -eq 1 ]" "auto termux-usb -r once"
assert "grep -q -- '-r /dev/bus/usb/001/002' \"$STATE/usb.log\"" " -r uses discovered device"
assert "! grep -q USB_PERM_DENIED \"$TICK\"" "no USB_PERM_DENIED after successful retry"
assert "grep -q -- '--title HiDock needs USB OK' \"$STATE/notify.log\"" "notify while requesting so the dialog is seen"
assert "grep -q 'auto-requesting USB permission' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "tick log notes auto-request"

echo
echo "== still denied after one retry: USB_PERM_DENIED + notify + exit 1"
echo deny_always > "$STATE/usb_mode"
: > "$TICK"
RC=0
run_sync --dry-run || RC=$?
assert "[ \"$RC\" -eq 1 ]" "still-denied exits 1"
assert "[ \"\$(wc -l < \"$STATE/usb_e.count\")\" -eq 2 ]" "exactly one retry (two -e calls)"
assert "[ \"\$(wc -l < \"$STATE/usb_r.count\")\" -eq 1 ]" "exactly one auto -r"
assert "grep -q '^USB_PERM_DENIED ' \"$TICK\"" "USB_PERM_DENIED on adb tick file"
assert "grep -q 'device=/dev/bus/usb/001/002' \"$TICK\"" "denied line names the device"
assert "grep -q 'boot_id=' \"$TICK\"" "denied line includes boot_id"
assert "grep -q '^USB_PERM_DENIED ' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "USB_PERM_DENIED on cron_ticks.log"
assert "grep -q -- '--title HiDock needs USB OK' \"$STATE/notify.log\"" "notification title"
assert "grep -q -- '--id hidock-usb-perm' \"$STATE/notify.log\"" "stable notification id"
assert "grep -qi 'tap OK' \"$STATE/notify.last_args\"" "body tells user to tap OK"
assert "grep -qi 'reboot' \"$STATE/notify.last_args\"" "body says expected after reboot"

echo
echo "== non-permission termux-usb failure does not auto-request"
echo busy > "$STATE/usb_mode"
: > "$TICK"
RC=0
run_sync || RC=$?
assert "[ \"$RC\" -eq 0 ]" "non-permission failure keeps prior exit-0 wrapper behavior"
assert "[ \"\$(wc -l < \"$STATE/usb_e.count\")\" -eq 1 ]" "no retry on non-permission error"
assert "[ ! -f \"$STATE/usb_r.count\" ]" "no -r on device-busy"
assert "! grep -q USB_PERM_DENIED \"$TICK\"" "no USB_PERM_DENIED on device-busy"
assert "[ ! -s \"$STATE/notify.log\" ]" "no notification on device-busy"
assert "grep -q 'termux-usb returned 7' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "busy RC logged"

echo
echo "== request subcommand still only calls -r (no -e loop)"
echo ok > "$STATE/usb_mode"
: > "$TICK"
RC=0
run_sync request || RC=$?
assert "[ \"$RC\" -eq 0 ]" "request exits 0"
assert "[ ! -f \"$STATE/usb_e.count\" ]" "request does not open via -e"
assert "[ \"\$(wc -l < \"$STATE/usb_r.count\")\" -eq 1 ]" "request calls -r once"
assert "! grep -q USB_PERM_DENIED \"$TICK\"" "request does not write USB_PERM_DENIED"

echo
echo "== still-denied without termux-notification still logs and exits 1"
BIN_NONOTIFY="$WORKDIR/bin_nonotify"
mkdir -p "$BIN_NONOTIFY"
cp "$BIN/termux-usb" "$BIN_NONOTIFY/"
echo deny_always > "$STATE/usb_mode"
: > "$TICK"
rm -f "$STATE/usb_e.count" "$STATE/usb_r.count"
rm -f "$HOME_DIR/.config/hidock-sync/cron_ticks.log"
RC=0
JOB_TICK_FILE="$TICK" HOME="$HOME_DIR" PATH="$BIN_NONOTIFY:/usr/bin:/bin" \
    bash "$ROOT/run_sync.sh" --dry-run || RC=$?
assert "[ \"$RC\" -eq 1 ]" "missing notifier still exits 1"
assert "grep -q '^USB_PERM_DENIED ' \"$TICK\"" "USB_PERM_DENIED without termux-notification"
assert "grep -q '^USB_PERM_DENIED ' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "cron_ticks.log written without notifier"
assert "grep -q 'termux-notification not on PATH' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "logs that notify was skipped"

echo
echo "== job_fire.sh + run_sync.sh still-denied writes JOB_FIRE then USB_PERM_DENIED"
echo deny_always > "$STATE/usb_mode"
: > "$TICK"
: > "$STATE/usb.log"
: > "$STATE/notify.log"
rm -f "$STATE/usb_e.count" "$STATE/usb_r.count"
rm -f "$HOME_DIR/.config/hidock-sync/cron_ticks.log"
RC=0
JOB_TICK_FILE="$TICK" HOME="$HOME_DIR" PATH="$BIN:$PATH" \
    bash "$ROOT/job_fire.sh" --dry-run || RC=$?
assert "[ \"$RC\" -eq 1 ]" "job_fire propagates still-denied exit 1"
assert "grep -q '^JOB_FIRE ' \"$TICK\"" "JOB_FIRE still written"
assert "grep -q '^USB_PERM_DENIED ' \"$TICK\"" "USB_PERM_DENIED appended to same tick file"
assert "grep -q '^JOB_FIRE ' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "JOB_FIRE in cron_ticks.log"
assert "grep -q '^USB_PERM_DENIED ' \"$HOME_DIR/.config/hidock-sync/cron_ticks.log\"" "USB_PERM_DENIED in cron_ticks.log"
assert "grep -q -- '--title HiDock needs USB OK' \"$STATE/notify.log\"" "JobScheduler path notifies"
assert "[ \"\$(wc -l < \"$STATE/usb_r.count\")\" -eq 1 ]" "JobScheduler path auto-requests once"

echo
if [ "$FAILS" -ne 0 ]; then
    echo "$FAILS assertion(s) failed"
    echo "---- usb.log ----"; cat "$STATE/usb.log" || true
    echo "---- ticks ----"; cat "$TICK" || true
    echo "---- cron_ticks.log ----"; cat "$HOME_DIR/.config/hidock-sync/cron_ticks.log" || true
    echo "---- notify.log ----"; cat "$STATE/notify.log" || true
    exit 1
fi
echo "All USB permission wrapper tests passed."
