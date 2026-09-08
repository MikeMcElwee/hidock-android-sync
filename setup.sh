#!/data/data/com.termux/files/usr/bin/bash
# One-shot installer. Idempotent.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
HERE="$(pwd)"

echo "==> Installing Termux packages"
yes | pkg update
yes | pkg install -y python libusb termux-api ffmpeg rclone cronie termux-services git clang make pkg-config

echo "==> Installing pyusb"
pip install --user pyusb

echo "==> Cloning sgeraldes/hidock-next (Jensen protocol)"
if [ ! -d "$HERE/hidock-next" ]; then
    git clone --depth 1 https://github.com/sgeraldes/hidock-next.git "$HERE/hidock-next"
else
    echo "    already cloned, skipping"
fi
test -f "$HERE/hidock-next/apps/desktop/src/hidock_device.py"

echo "==> Seeding default config"
mkdir -p "$HOME/.config/hidock-sync"
if [ ! -f "$HOME/.config/hidock-sync/config" ]; then
    cp "$HERE/config.example.env" "$HOME/.config/hidock-sync/config"
    # rewrite HIDOCK_NEXT_DIR to absolute path of this checkout
    sed -i "s|HIDOCK_NEXT_DIR=.*|HIDOCK_NEXT_DIR=$HERE/hidock-next|" "$HOME/.config/hidock-sync/config"
fi

echo
echo "==> Done. Next steps:"
echo "    1. rclone config create gdrive drive scope drive   # OAuth in browser"
echo "    2. Plug in the HiDock"
echo "    3. bash run_sync.sh request                         # grant USB (again after each reboot)"
echo "    4. bash run_sync.sh --dry-run --limit 3             # see what would happen"
echo "    5. bash setup-jobscheduler.sh                       # persisted JobScheduler (not cron)"
