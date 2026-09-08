# hidock-android-sync

Pull recordings off a **HiDock P1 mini** voice recorder via your Android phone over USB,
transcode them to `.m4a`, upload to **Google Drive**, and delete from the device — all
fully automatic, on a persisted Android JobScheduler interval, with no PC needed.

The HiDock device speaks a proprietary "Jensen" USB protocol and only enumerates when
plugged into a phone-class USB host (it won't talk to a Mac/PC directly). This script
runs entirely inside [Termux](https://termux.dev/) on the phone and uses Android's
`UsbManager` to grant the USB device a file descriptor that
[`libusb_wrap_sys_device`](https://libusb.sourceforge.io/api-1.0/group__libusb__dev.html#ga98f0967e6e72b327fae6c8b0d51fbcd2)
hands to [pyusb](https://github.com/pyusb/pyusb), so we never need root.

The Jensen protocol implementation is consumed unmodified from
[`sgeraldes/hidock-next`](https://github.com/sgeraldes/hidock-next) (MIT licensed) — this
repo is a thin Termux/Android adapter on top of it, plus a JobScheduler-driven Drive uploader.

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
| Apps | Termux + Termux:API (install **both from F-Droid** or both from the [Termux GitHub releases](https://github.com/termux) — they share signing keys; you cannot mix). Termux:Boot is **optional insurance** only; persisted JobScheduler jobs are owned by Termux:API and should survive reboot without it. |
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
import its `hidock_device.py` for the Jensen protocol). `cronie` is only needed
if you still run the deprecated `setup-cron.sh`; the supported scheduler is
`termux-job-scheduler` from `termux-api`.

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
# 7) Enable persisted JobScheduler (survives reboot; do not use cron)
bash setup-jobscheduler.sh
```

That installs Android JobScheduler job **834001** via `termux-job-scheduler`
(`--persisted true`, `--battery-not-low false` so a low battery still syncs,
`--network any`, period from `CRON_INTERVAL_MIN`, default 30 min → `1800000` ms).
It also **clears crontab, stops crond**, and replaces `~/.termux/boot/start-crond`
with a thin re-assert of that same job. Termux:Boot is optional insurance —
persisted jobs should already fire after a cold boot without opening Termux.

`setup-cron.sh` is **deprecated**. Termux:Boot + crond did not reliably resume
after a real phone reboot.

## After install

```bash
bash run_sync.sh                     # manual full sync
tail -f ~/.config/hidock-sync/sync.log
termux-job-scheduler -p              # list pending JobScheduler jobs
```

### List / cancel the schedule

```bash
termux-job-scheduler -p
# expect: Job 834001: …/job_fire.sh (periodic: 1800000ms) (persisted)
#         — and NOT "(battery not low)" (we pass --battery-not-low false)

termux-job-scheduler --cancel --job-id 834001
# or: bash setup-jobscheduler.sh --cancel
```

Re-run `bash setup-jobscheduler.sh` to re-register the same job id (idempotent).

### Cold-boot prove

Do this once after install. The point is to prove JobScheduler fires **without**
a Termux session (the failure mode of Termux:Boot + crond).

1. Confirm the job is pending: `termux-job-scheduler -p` (job **834001**,
   `(persisted)`, period matching `CRON_INTERVAL_MIN`).
2. Optional snapshot so you can tell pre- vs post-reboot ticks:
   ```bash
   adb shell cat /sdcard/Download/hidock_job_ticks.txt
   ```
3. **Reboot the phone. Do not open Termux, Termux:API, or Termux:Boot.**
4. Wait at least one period (default 30 min; Android may add a few minutes of
   flex). Then, from a PC:
   ```bash
   adb shell cat /sdcard/Download/hidock_job_ticks.txt
   ```
   A new `JOB_FIRE …` line whose timestamp (and `boot_id=`) is after the reboot
   proves the job ran without anyone opening Termux.
5. After `JOB_FIRE` is proved, check that same tick's sync log
   (`~/.config/hidock-sync/cron_ticks.log`). JobScheduler itself is fine.
   Android still wipes the USB grant on cold boot, so the first post-reboot
   tick may auto-run `termux-usb -r` and show the system dialog. Tap **OK**.
   If the dialog is missed, look for `USB_PERM_DENIED` in
   `/sdcard/Download/hidock_job_ticks.txt` and a **HiDock needs USB OK**
   notification. Unplug/replug can also re-trigger attach flows. See
   [USB permission wiped after cold boot](#usb-permission-wiped-after-cold-boot)
   and the [full Termux:API patch recipe](docs/termux-api-usb-persist.md).
6. Confirm Android still has the persisted job owned by Termux:API:
   ```bash
   adb shell dumpsys jobscheduler | grep -A 40 'com.termux.api'
   ```
   Look for job id **834001** and a persisted `JobSchedulerAPI$JobSchedulerService`
   entry. `grep 834001` on that dump is usually enough.
7. If there is no post-reboot tick: Settings → Apps → **Termux:API** and
   **Termux** → Battery → **Unrestricted**, re-run `bash setup-jobscheduler.sh`,
   and repeat the reboot. Do not "fix" this by going back to `setup-cron.sh`.

## Configuration

`~/.config/hidock-sync/config` (created by step 3 above; defaults sane):

```bash
DRIVE_REMOTE=gdrive                  # name of your rclone remote
DRIVE_BASE=HiDock/Documents          # path inside the Drive
STAGING_DIR=/sdcard/Download/hidock_staging
LOG_DIR=$HOME/.config/hidock-sync
CRON_INTERVAL_MIN=30                 # setup-jobscheduler.sh → --period-ms (min 15)
```

---

## Troubleshooting

### "no USB device attached, skipping" in the tick log
Plug in HiDock and reseat. `termux-usb -l` should print the `/dev/bus/usb/X/Y` path.
After a cold boot this can also be a wiped USB grant even though the dock is
plugged in — see [USB permission wiped after cold boot](#usb-permission-wiped-after-cold-boot).

### "Permission denied" from `termux-usb`
Android has not granted Termux:API (`com.termux.api`) access to this USB
device, or it wiped that grant after a cold boot. `run_sync.sh` now detects
that from `termux-usb -e`, runs `termux-usb -r "$DEV"` once, and retries
`-e`. Tap **OK** on the dialog. If the retry is still denied, the wrapper
exits non-zero, writes `USB_PERM_DENIED` to the tick logs, and fires a
**HiDock needs USB OK** notification. This is **not** an OS-level persist —
see [USB permission wiped after cold boot](#usb-permission-wiped-after-cold-boot).

You can still grant manually:

```bash
bash run_sync.sh request
# or, on the path from termux-usb -l:
termux-usb -r /dev/bus/usb/X/Y
```

### USB permission wiped after cold boot
Phone-proved: JobScheduler job **834001** survives reboot and fires
(`JOB_FIRE` in `/sdcard/Download/hidock_job_ticks.txt`). JobScheduler itself
is fine.

**Android limitation (not a JobScheduler bug):** USB host permissions do not
persist across reboot for third-party apps unless the **same package that
opens the device** (`com.termux.api`) has a `USB_DEVICE_ATTACHED`
device-filter and a remembered grant. Stock Termux:API has no HiDock
device-filter. `adb` cannot grant this.

Until you tap **OK** again, the job still runs but `termux-usb -e` returns
`Permission denied` (or the tick logs `no USB device attached, skipping`).
`run_sync.sh` mitigates by auto-requesting once and notifying; it does
**not** survive the next cold boot on its own.

Unplug/replug after reboot can also re-trigger Android USB attach flows
(and another permission dialog).

True hands-off ingest after reboot needs a remembered grant on
`com.termux.api` (stock Termux:API cannot persist). The
[full Termux:API patch recipe](docs/termux-api-usb-persist.md) covers the
`device_filter` (P1 mini vendor-id `14471` / `0x3887`, product-id `8257` /
`0x2041`) plus `directBootAware`. An Accessibility auto-tap of the USB
OK dialog is a separate workaround.

Do not treat a persisted JobScheduler job as a USB grant. The supported
scheduler is still JobScheduler (`setup-jobscheduler.sh`); cron is
deprecated.

### HiNotes app holds the device, sync fails
The HiNotes app auto-attaches to the HiDock on USB-attach and locks it. You have three
options:
1. **Recommended:** uninstall HiNotes — you don't need it once this script is running.
2. Make Termux:API the default handler for the HiDock USB device (Settings → Apps →
   Default apps → USB device assistance → HiDock P1 mini → Termux:API).
3. Force-stop HiNotes manually before each scheduled tick (not feasible for unattended
   use without root or `adb`).

### Phone goes to sleep, jobs stop firing
JobScheduler is supposed to wake the device; it does **not** need a permanent
`termux-wake-lock` the way crond did.
- Settings → Apps → Termux → Battery → **Unrestricted** (Samsung) or **Don't optimize**.
- Same for **Termux:API** (it owns the persisted job).
- Termux:Boot is optional; if you installed it, Unrestricted is still wise.

### Job does not fire after reboot
This is the failure we moved off crond to fix. Persisted jobs live in Android's
JobScheduler under `com.termux.api`, not in a Termux session.

- `termux-job-scheduler -p` should still list job **834001** after you open Termux.
- `adb shell cat /sdcard/Download/hidock_job_ticks.txt` should gain a `JOB_FIRE`
  line after the next period — **without** opening Termux.
- `adb shell dumpsys jobscheduler` should show `com.termux.api` job **834001**.
- If the job vanished: battery restrictions likely killed Termux:API. Set it
  Unrestricted and re-run `bash setup-jobscheduler.sh`.
- Do not treat Termux:Boot + `setup-cron.sh` as the fix. That path is deprecated.

### Tokens / re-auth
`rclone` saves OAuth refresh tokens in `~/.config/rclone/rclone.conf`. If Drive
returns 401, run `rclone config reconnect gdrive:` and re-auth.

### Mid-record scheduled tick / live file skip
Each tick asks Jensen `get_recording_file` (CMD_GET_RECORDING_FILE) for the
in-progress filename and **skips that file** — no pull, transcode, upload, or
delete. `--dry-run` still prints the skip decision.

If that call raises, returns nothing, or returns an empty name, sync runs over
the full file list as before (fail-open so a flaky query cannot stall the queue).

**Caveat:** Jensen documents this API as the *active or last* recording. If
firmware reports the last completed file while the device is idle, that file
stays on the device until a new recording starts (the next tick after that will
see a different name and can sync the previous one).

---

## How it works

1. **`job_fire.sh`** is the JobScheduler entrypoint (job 834001). It writes a
   `JOB_FIRE` line to `/sdcard/Download/hidock_job_ticks.txt` (adb-readable)
   and execs `run_sync.sh`.
2. **`run_sync.sh`** discovers the HiDock USB device with `termux-usb -l`, then runs
   the sync script as a child of `termux-usb -e`. Termux:API opens the device through
   `UsbManager.openDevice()` and passes the resulting file descriptor to our process.
   If `-e` fails with permission denied (typical after a cold boot), the wrapper
   auto-runs `termux-usb -r` and retries once. Still denied → `USB_PERM_DENIED`
   on the tick logs plus a **HiDock needs USB OK** notification. This does not
   persist the grant across reboot.
3. **`hidock_sync.py`** parses that fd, calls
   [`libusb_wrap_sys_device`](https://libusb.sourceforge.io/api-1.0/group__libusb__dev.html#ga98f0967e6e72b327fae6c8b0d51fbcd2)
   via ctypes, and constructs a fully-functional `usb.core.Device`. A small
   monkey-patch on `backend.open_device` keeps pyusb from re-opening the (already
   open) handle.
4. **`HiDockJensen`** from `sgeraldes/hidock-next` is then driven directly: list files,
   skip the live/last file reported by `get_recording_file` (if any), stream-pull
   each remaining file, and `delete_file` on success.
5. Each pulled `.hda` is transcoded to `.m4a` (AAC 64 kbps mono) with `ffmpeg`, then
   `rclone copyto`'d to Drive with `--ignore-existing` (idempotent).
6. `delete_file` on the device runs **only after** the Drive copy returns 200, so a
   network failure never destroys data.

## Repo layout
```
hidock-android-sync/
├── README.md
├── docs/termux-api-usb-persist.md  # custom Termux:API USB grant persist recipe
├── LICENSE
├── config.example.env       # default config; user copies to ~/.config/hidock-sync/config
├── hidock_sync.py           # main worker, run via `termux-usb -e`
├── test_live_skip.py        # unit tests for mid-record skip (no USB needed)
├── test_jobscheduler_setup.sh # offline tests for JobScheduler setup + wrapper
├── test_usb_perm.sh         # offline tests for USB perm auto-request + notify
├── run_sync.sh              # scheduler-friendly ingest wrapper
├── job_fire.sh              # JobScheduler entrypoint (JOB_FIRE + run_sync.sh)
├── job_run_sync.sh          # thin alias → job_fire.sh (phone checkouts that registered this name)
├── setup.sh                 # one-shot installer (pkg install + clone hidock-next)
├── setup-jobscheduler.sh    # supported: persisted JobScheduler job 834001
└── setup-cron.sh            # DEPRECATED cron + Termux:Boot fallback
```

## Credits
- The Jensen USB protocol implementation lives in [`sgeraldes/hidock-next`](https://github.com/sgeraldes/hidock-next).
- The libusb fd-passing recipe is the standard Termux ↔ Android USB pattern documented in the [pyusb FAQ](https://github.com/pyusb/pyusb/blob/master/docs/faq.rst).

## License
MIT — see [LICENSE](./LICENSE).
