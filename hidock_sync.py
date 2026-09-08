#!/data/data/com.termux/files/usr/bin/env python3
"""
HiDock → Google Drive sync (Termux + libusb fd-passing).

Run via:
    termux-usb -e "python hidock_sync.py [--dry-run] [--limit N]" /dev/bus/usb/X/Y

For each .hda recording on the HiDock device:
  1) stream-pull bytes to $STAGING_DIR
  2) ffmpeg-transcode to .m4a (AAC, $M4A_BITRATE)
  3) rclone copyto $DRIVE_REMOTE:$DRIVE_BASE/YYYY-MM-DD/HH-MM-SS_RecNN.m4a
  4) delete_file on the device  (only after Drive returns 200)
  5) clean staging files

Idempotent: source of truth is the device. If anything fails before step 4,
the file stays on the device and is retried next tick. rclone uses
--ignore-existing so a partial state never destroys data on Drive.

Configuration: env vars from ~/.config/hidock-sync/config (sourced by run_sync.sh)
or set explicitly:
    DRIVE_REMOTE      default: gdrive
    DRIVE_BASE        default: HiDock/Documents
    STAGING_DIR       default: /sdcard/Download/hidock_staging
    LOG_DIR           default: ~/.config/hidock-sync
    M4A_BITRATE       default: 64k
    HIDOCK_NEXT_DIR   default: <repo>/hidock-next
"""

import argparse
import ctypes
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent
DRIVE_REMOTE = os.environ.get("DRIVE_REMOTE", "gdrive")
DRIVE_BASE = os.environ.get("DRIVE_BASE", "HiDock/Documents")
STAGING_DIR = Path(os.environ.get("STAGING_DIR", "/sdcard/Download/hidock_staging"))
LOG_DIR = Path(os.environ.get("LOG_DIR", str(Path.home() / ".config/hidock-sync")))
M4A_BITRATE = os.environ.get("M4A_BITRATE", "64k")
HIDOCK_NEXT_DIR = Path(os.environ.get("HIDOCK_NEXT_DIR", str(REPO / "hidock-next")))

JENSEN_SRC = HIDOCK_NEXT_DIR / "apps" / "desktop" / "src"
if not JENSEN_SRC.exists():
    sys.exit(f"hidock-next sources missing at {JENSEN_SRC}. Run setup.sh first.")
sys.path.insert(0, str(JENSEN_SRC))

import usb.core           # noqa: E402
import usb.util           # noqa: E402
import usb.backend.libusb1  # noqa: E402
from hidock_device import HiDockJensen  # noqa: E402

MONTHS = {m: f"{i:02d}" for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], start=1)}
NAME_RE = re.compile(
    r"^(?P<year>\d{4})(?P<mon>[A-Z][a-z]{2})(?P<day>\d{2})-"
    r"(?P<hh>\d{2})(?P<mm>\d{2})(?P<ss>\d{2})"
    r"(?:-(?P<suffix>[A-Za-z0-9]+))?\.hda$"
)


class _Tee:
    def __init__(self, *streams): self.streams = streams
    def write(self, s):
        for st in self.streams:
            try: st.write(s); st.flush()
            except Exception: pass
    def flush(self):
        for st in self.streams:
            try: st.flush()
            except Exception: pass


def now(): return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
def log(msg): print(f"[{now()}] {msg}", flush=True)


def resolve_live_skip_name(active):
    """Basename to skip this tick, or None (fail-open) if unavailable/empty."""
    if not isinstance(active, dict):
        return None
    name = active.get("name")
    if name is None:
        return None
    name = str(name).strip()
    if not name:
        return None
    return Path(name).name


def query_live_skip_name(jensen, timeout_s=5):
    """Ask Jensen CMD_GET_RECORDING_FILE. None on raise / empty (fail-open)."""
    try:
        active = jensen.get_recording_file(timeout_s=timeout_s)
    except Exception:
        return None
    return resolve_live_skip_name(active)


def is_live_skip(name, skip_name):
    if not skip_name or not name:
        return False
    return name == skip_name or Path(name).name == skip_name


def parse_name(name):
    m = NAME_RE.match(name)
    if not m: return None
    g = m.groupdict()
    mon = MONTHS.get(g["mon"])
    if not mon: return None
    return {
        "date": f"{g['year']}-{mon}-{g['day']}",
        "time": f"{g['hh']}-{g['mm']}-{g['ss']}",
        "suffix": g.get("suffix") or "",
    }


def target_m4a_name(parsed):
    return parsed["time"] + (f"_{parsed['suffix']}" if parsed["suffix"] else "") + ".m4a"


def wrap_fd_to_pyusb_device(fd):
    """Take a pre-opened USB file descriptor from termux-usb and return a
    fully-functional usb.core.Device (already opened/configured by Android)."""
    backend = usb.backend.libusb1.get_backend()
    if backend is None:
        raise RuntimeError("libusb1 backend not loadable; install `pkg install libusb`")
    lib = backend.lib
    lib.libusb_wrap_sys_device.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.libusb_wrap_sys_device.restype = ctypes.c_int
    lib.libusb_get_device.argtypes = [ctypes.c_void_p]
    lib.libusb_get_device.restype = ctypes.c_void_p
    lib.libusb_ref_device.argtypes = [ctypes.c_void_p]
    lib.libusb_ref_device.restype = ctypes.c_void_p

    dev_handle = ctypes.c_void_p()
    rc = lib.libusb_wrap_sys_device(backend.ctx, fd, ctypes.byref(dev_handle))
    if rc != 0:
        raise OSError(f"libusb_wrap_sys_device returned {rc}")
    libusb_device_ptr = lib.libusb_get_device(dev_handle)
    lib.libusb_ref_device(libusb_device_ptr)

    libusb1_mod = sys.modules["usb.backend.libusb1"]
    DevType = getattr(libusb1_mod, "_Device")
    DevHandle = getattr(libusb1_mod, "_DeviceHandle")
    bdev = DevType(libusb_device_ptr)
    dh = DevHandle.__new__(DevHandle)
    dh.handle = dev_handle
    dh.devid = libusb_device_ptr

    real_open = backend.open_device
    def open_device(d):
        if getattr(d, "devid", None) == libusb_device_ptr:
            return dh
        return real_open(d)
    backend.open_device = open_device

    return usb.core.Device(bdev, backend), backend


def setup_endpoints(device, intf_num=0):
    cfg = device.get_active_configuration()
    intf = usb.util.find_descriptor(cfg, bInterfaceNumber=intf_num)
    if intf is None:
        raise RuntimeError(f"interface {intf_num} not found")
    ep_in = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    ep_out = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    if ep_in is None or ep_out is None:
        raise RuntimeError("bulk IN/OUT endpoints not found")
    return intf, ep_in, ep_out


def fmt_size(b):
    for u in ("B", "KB", "MB", "GB"):
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} TB"


def stream_to_file(jensen, name, size, dst, timeout_s=600):
    recv = [0]
    with open(dst, "wb") as fh:
        def on_data(chunk):
            fh.write(chunk)
            recv[0] += len(chunk)
        status = jensen.stream_file(filename=name, file_length=size,
                                    data_callback=on_data,
                                    progress_callback=lambda r, t: None,
                                    timeout_s=timeout_s)
    return status, dst.stat().st_size


def transcode_to_m4a(src, dst):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-i", str(src), "-c:a", "aac", "-b:a", M4A_BITRATE, str(dst)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {res.stderr.strip()}")
    if not dst.exists() or dst.stat().st_size == 0:
        raise RuntimeError("ffmpeg produced empty output")


def rclone_upload(local, drive_path):
    cmd = ["rclone", "copyto", "--ignore-existing", "--retries", "3",
           str(local), drive_path]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if res.returncode != 0:
        raise RuntimeError(f"rclone failed: {res.stderr.strip() or res.stdout.strip()}")


def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_fh = open(LOG_DIR / "sync.log", "a", buffering=1)
    sys.stdout = _Tee(sys.stdout, log_fh)
    sys.stderr = _Tee(sys.stderr, log_fh)
    log("===== hidock_sync start =====")

    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0,
                    help="Process at most N files this run (0 = all)")
    # termux-usb appends a bare integer (the fd) as the last argv token.
    argv = list(sys.argv[1:])
    fd = None
    for i in range(len(argv) - 1, -1, -1):
        if argv[i].isdigit():
            fd = int(argv[i])
            del argv[i]
            break
    args = ap.parse_args(argv)
    if fd is None:
        log("ERROR: no fd provided; this script must be run via `termux-usb -e`")
        return 1

    STAGING_DIR.mkdir(parents=True, exist_ok=True)
    log(f"fd={fd} dry_run={args.dry_run} drive={DRIVE_REMOTE}:{DRIVE_BASE}")

    dev, backend = wrap_fd_to_pyusb_device(fd)
    log(f"device vid={hex(dev.idVendor)} pid={hex(dev.idProduct)}")
    intf, ep_in, ep_out = setup_endpoints(dev, 0)

    jensen = HiDockJensen(backend)
    jensen.device = dev
    jensen.ep_in = ep_in
    jensen.ep_out = ep_out
    jensen.is_connected_flag = True
    jensen.claimed_interface_number = intf.bInterfaceNumber
    jensen.detached_kernel_driver_on_interface = -1

    try:
        info = jensen.get_device_info(timeout_s=10)
        log(f"device info: {info}")
    except Exception as e:
        log(f"WARN device info: {e}")

    log("listing device files...")
    files = jensen.list_files(timeout_s=60).get("files", [])
    log(f"{len(files)} files on device, {fmt_size(sum(f.get('length', 0) for f in files))} total")

    # Mid-record protection: skip the live take so a cron tick cannot pull/delete it.
    # Fail-open: if get_recording_file raises / returns None / empty name, sync the full list.
    skip_name = query_live_skip_name(jensen, timeout_s=5)
    if skip_name:
        log(f"SKIP live/recording file this tick: {skip_name}")
    else:
        log("WARN get_recording_file unavailable/empty — not skipping any file")

    processed = 0
    skipped = 0
    failures = []

    for idx, f in enumerate(files, 1):
        if args.limit and processed >= args.limit:
            log(f"limit {args.limit} reached, stopping")
            break
        name = f["name"]
        if is_live_skip(name, skip_name):
            log(f"[{idx}/{len(files)}] SKIP live/recording file: {name}")
            skipped += 1
            continue
        size = f["length"]
        parsed = parse_name(name)
        if not parsed:
            log(f"[{idx}/{len(files)}] SKIP unparseable: {name}")
            skipped += 1
            continue

        m4a_name = target_m4a_name(parsed)
        drive_path = f"{DRIVE_REMOTE}:{DRIVE_BASE}/{parsed['date']}/{m4a_name}"
        local_hda = STAGING_DIR / name
        local_m4a = STAGING_DIR / m4a_name

        log(f"[{idx}/{len(files)}] {name} {fmt_size(size)} -> {parsed['date']}/{m4a_name}")
        if args.dry_run:
            log(f"    DRY-RUN: pull -> ffmpeg -> rclone copyto {drive_path} -> delete_file")
            continue

        try:
            t0 = time.time()
            log("    pull from device...")
            status, got = stream_to_file(jensen, name, size, local_hda)
            if status != "OK" or got != size:
                raise RuntimeError(f"pull bad status={status} got={got} want={size}")
            log(f"    pulled {fmt_size(got)} in {time.time()-t0:.1f}s")

            log("    transcode .hda -> .m4a")
            transcode_to_m4a(local_hda, local_m4a)
            log(f"    m4a {fmt_size(local_m4a.stat().st_size)}")

            log(f"    upload to {drive_path}")
            rclone_upload(local_m4a, drive_path)

            log("    delete from device")
            jensen.delete_file(name, timeout_s=10)

            local_hda.unlink(missing_ok=True)
            local_m4a.unlink(missing_ok=True)
            processed += 1
            log("    OK")
        except Exception as e:
            log(f"    FAIL: {e}")
            failures.append((name, str(e)))
            for p in (local_hda, local_m4a):
                try: p.unlink(missing_ok=True)
                except Exception: pass

    log(f"summary: processed={processed} skipped={skipped} failed={len(failures)}")
    for n, e in failures:
        log(f"  FAIL {n}: {e}")
    log("===== hidock_sync end =====")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
