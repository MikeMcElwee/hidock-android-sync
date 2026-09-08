#!/data/data/com.termux/files/usr/bin/bash
# Alias for phone checkouts that registered -s …/job_run_sync.sh.
# Prefer job_fire.sh for new installs.
exec "$(dirname "$(readlink -f "$0")")/job_fire.sh" "$@"
