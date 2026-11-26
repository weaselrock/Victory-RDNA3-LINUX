#!/usr/bin/env bash
# Takes a processor profile of the running game with Linux perf.
# Start the game, get into the world, then in a second terminal:
#
#   bash scripts/linux/profile-victory.sh [seconds]
#
# It only reads the running game. Results go to <run-dir>/profiles/<time>.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
work=${VICTORY_WORK_DIR:-$(dirname -- "$repo")}
data=${VICTORY_RUN_DIR:-$work/victory-run}
seconds=${1:-20}

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Run this as yourself, not with sudo. It asks for sudo where it needs it."
[[ $seconds =~ ^[1-9][0-9]*$ ]] || fail "Usage: profile-victory.sh [seconds]"
perf --version >/dev/null 2>&1 || fail "perf is missing. Install it with:
  sudo apt install linux-tools-$(uname -r)"

pids=$(pgrep -f 'victory\.exe run ' | paste -sd, || true)
[[ -n $pids ]] || fail "The game is not running. Start it and get into the world first."
# the game is the one of these processes that holds the most memory
pid=$(ps -o pid=,rss= -p "$pids" | sort -k2 -nr | awk 'NR == 1 { print $1 }')

out=$data/profiles/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
sudo -v

{
    uname -r
    lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|max MHz' || true
    for name in scaling_driver scaling_governor energy_performance_preference; do
        printf '%s: %s\n' "$name" "$(cat "/sys/devices/system/cpu/cpu0/cpufreq/$name" 2>/dev/null || echo none)"
    done
    printf 'power profile: %s\n' "$(powerprofilesctl get 2>/dev/null || echo unknown)"
    echo "kernel features the game has open:"
    sudo ls -l "/proc/$pid/fd" | grep -o -E 'userfaultfd|/dev/ntsync' | sort | uniq -c || echo none
} >"$out/system.txt"
sudo cat "/proc/$pid/maps" >"$out/maps.txt"

echo "Profiling for $seconds seconds. Switch back to the game and keep playing."
sleep 5
sudo perf record -F 999 -p "$pid" -o "$out/perf.data" -- sleep "$seconds"

echo "Writing the reports (this can take a minute)..."
report() {
    sudo perf report -i "$out/perf.data" --stdio --percent-limit "$3" --sort "$1" >"$out/$2" 2>"$out/$2.err" ||
        echo "report $2 failed, see $out/$2.err" >&2
}
report pid threads.txt 0.2
report dso modules.txt 0.1
report pid,dso thread-modules.txt 0.2
report dso,sym functions.txt 0.1
report pid,dso,sym thread-functions.txt 0.2
sudo chown "$(id -u):$(id -g)" "$out/perf.data"
chmod 644 "$out"/*

echo "Done: $out"
