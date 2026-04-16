# hidock-android-sync

Pull recordings off a **HiDock P1 mini** voice recorder via your Android phone over USB,
transcode them to `.m4a`, upload to **Google Drive**, and delete from the device — all
fully automatic, on a cron schedule, with no PC needed.

The HiDock device speaks a proprietary "Jensen" USB protocol and only enumerates when
plugged into a phone-class USB host (it won't talk to a Mac/PC directly). This script
runs entirely inside [Termux](https://termux.dev/) on the phone and uses Android's
`UsbManager` to grant the USB device a file descriptor that
[`libusb_wrap_sys_device`](https://libusb.sourceforge.io/api-1.0/group__libusb__dev.html#ga98f0967e6e72b327fae6c8b0d51fbcd2)
hands to [pyusb](https://github.com/pyusb/pyusb), so we never need root.

The Jensen protocol implementation is consumed unmodified from
[`sgeraldes/hidock-next`](https://github.com/sgeraldes/hidock-next) (MIT licensed) — this
repo is a thin Termux/Android adapter on top of it, plus a cron-friendly Drive uploader.

## What it does on each tick

```
HiDock P1 mini  ──USB──►  Phone (Termux)  ──HTTPS──►  Google Drive
                                    │
                                    └─ ffmpeg .hda → .m4a (AAC 64k)
                                    └─ delete_file on device after Drive 200 OK
```

Every file lands in Drive at:
```
{DRIVE_BASE}/YYYY-MM-DD/HH-MM-SS_RecNN.m4a
```
(parsed from the HiDock's native filename `YYYYMmm DD-HHMMSS-RecNN.hda`).

## Why you might want this

- The official HiNotes app holds your recordings in private app storage you can't easily
  back up. This script puts them in Drive permanently.
- Your phone has unlimited HiDock storage (just sync; device gets cleared automatically).
- Recordings become accessible on every device you own that can read Drive.
- No more dependence on the HiDock Cloud transcription quota — point any pipeline at
  your Drive folder.

---

## Requirements

| | |
|---|---|
| Hardware | Android phone with USB-C OTG, HiDock P1 mini (VID `0x3887` PID `0x2041`) |
| Apps | Termux + Termux:API + Termux:Boot (install **all three from F-Droid** or all three from the [Termux GitHub releases](https://github.com/termux) — they share signing keys; you cannot mix) |
| Account | A Google account with Drive |

Tested on Samsung Galaxy Z Fold 3 (Android 14) with HiDock P1 mini firmware 2.2.3.

---

## Install (one shot, ~5 min)

In a Termux session:

```bash
# 1) Install package deps + clone this repo + clone hidock-next
pkg install -y git
git clone https://github.com/mavliev/hidock-android-sync.git ~/hidock-android-sync
cd ~/hidock-android-sync
bash setup.sh
```

`setup.sh` installs `python libusb termux-api ffmpeg rclone cronie termux-services`,
`pip install pyusb`, and `git clone`s `sgeraldes/hidock-next` (read-only — we only
import its `hidock_device.py` for the Jensen protocol).

```bash
# 2) Configure rclone Google Drive remote (interactive — opens a browser tab)
rclone config create gdrive drive scope drive
```
The OAuth tab will open. Sign in, allow access, done.

If you also have a Mac/PC, the easier path is to run `rclone config` there, then:
```
adb push ~/.config/rclone/rclone.conf /sdcard/
# then in Termux:
mkdir -p ~/.config/rclone && cp /sdcard/rclone.conf ~/.config/rclone/
```

```bash
# 3) (optional) Customize config
cp config.example.env ~/.config/hidock-sync/config
$EDITOR ~/.config/hidock-sync/config       # change DRIVE_BASE etc. if you wish
```

```bash
# 4) Plug in the HiDock and grant USB permission once (a system dialog pops up)
bash run_sync.sh request

# 5) Test: dry-run lists what would be uploaded
bash run_sync.sh --dry-run --limit 3
```

If the dry-run looks right:
```bash
# 6) Real run with a single file
bash run_sync.sh --limit 1
```

Open the Drive web UI and confirm the `.m4a` appeared at `{DRIVE_BASE}/YYYY-MM-DD/`.

```bash
# 7) Enable cron + boot autostart
bash setup-cron.sh
```

## After install

```bash
bash run_sync.sh                     # manual full sync
tail -f ~/.config/hidock-sync/sync.log
crontab -l                           # see schedule
```

## Configuration

`~/.config/hidock-sync/config` (created by step 3 above; defaults sane):

```bash
DRIVE_REMOTE=gdrive                  # name of your rclone remote
DRIVE_BASE=HiDock/Documents          # path inside the Drive
STAGING_DIR=/sdcard/Download/hidock_staging
LOG_DIR=$HOME/.config/hidock-sync
CRON_INTERVAL_MIN=30                 # only used by setup-cron.sh
```

---

## Troubleshooting

### "no USB device attached, skipping" in the cron log
Plug in HiDock and reseat. `termux-usb -l` should print the `/dev/bus/usb/X/Y` path.

### "Permission denied" from `termux-usb`
You haven't granted the persistent permission yet. Run `bash run_sync.sh request`
once — Android will pop an "Allow Termux:API to access HiDock P1 mini?" dialog. Tap
**OK**. The grant is per device; survive reboots.

### HiNotes app holds the device, sync fails
The HiNotes app auto-attaches to the HiDock on USB-attach and locks it. You have three
options:
1. **Recommended:** uninstall HiNotes — you don't need it once this script is running.
2. Make Termux:API the default handler for the HiDock USB device (Settings → Apps →
   Default apps → USB device assistance → HiDock P1 mini → Termux:API).
3. Force-stop HiNotes manually before each cron tick (not feasible for unattended use
   without root or `adb`).

### Phone goes to sleep, cron stops firing
- `setup-cron.sh` calls `termux-wake-lock`. If you see no Termux notification, wake-lock
  is not held.
- Settings → Apps → Termux → Battery → **Unrestricted** (Samsung) or **Don't optimize**.
- Same for Termux:API and Termux:Boot.

### Cron doesn't fire after reboot
Termux:Boot must be **opened at least once** after install (it then registers the
`BOOT_COMPLETED` receiver). If you've never tapped its icon, do so. To verify the boot
script will run, check `~/.termux/boot/start-crond` exists and is executable.

### Tokens / re-auth
`rclone` saves OAuth refresh tokens in `~/.config/rclone/rclone.conf`. If Drive
returns 401, run `rclone config reconnect gdrive:` and re-auth.

---

## How it works

1. **`run_sync.sh`** discovers the HiDock USB device with `termux-usb -l`, then runs
   the sync script as a child of `termux-usb -e`. Termux:API opens the device through
   `UsbManager.openDevice()` and passes the resulting file descriptor to our process.
2. **`hidock_sync.py`** parses that fd, calls
   [`libusb_wrap_sys_device`](https://libusb.sourceforge.io/api-1.0/group__libusb__dev.html#ga98f0967e6e72b327fae6c8b0d51fbcd2)
   via ctypes, and constructs a fully-functional `usb.core.Device`. A small
   monkey-patch on `backend.open_device` keeps pyusb from re-opening the (already
   open) handle.
3. **`HiDockJensen`** from `sgeraldes/hidock-next` is then driven directly: list files,
   stream-pull each one, and `delete_file` on success.
4. Each pulled `.hda` is transcoded to `.m4a` (AAC 64 kbps mono) with `ffmpeg`, then
   `rclone copyto`'d to Drive with `--ignore-existing` (idempotent).
5. `delete_file` on the device runs **only after** the Drive copy returns 200, so a
   network failure never destroys data.

## Repo layout
```
hidock-android-sync/
├── README.md
├── LICENSE
├── config.example.env       # default config; user copies to ~/.config/hidock-sync/config
├── hidock_sync.py           # main worker, run via `termux-usb -e`
├── run_sync.sh              # cron-friendly wrapper
├── setup.sh                 # one-shot installer (pkg install + clone hidock-next)
└── setup-cron.sh            # enables cron + boot autostart + wake-lock
```

## Credits
- The Jensen USB protocol implementation lives in [`sgeraldes/hidock-next`](https://github.com/sgeraldes/hidock-next).
- The libusb fd-passing recipe is the standard Termux ↔ Android USB pattern documented in the [pyusb FAQ](https://github.com/pyusb/pyusb/blob/master/docs/faq.rst).

## License
MIT — see [LICENSE](./LICENSE).
