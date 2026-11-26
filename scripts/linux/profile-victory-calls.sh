#!/usr/bin/env bash
# Shows which system calls the running game spends processor time in.
# Start the game, get to a busy spot in the world, then in a second terminal:
#
#   bash scripts/linux/profile-victory-calls.sh
#
# It only reads the running game. Results go to <run-dir>/profiles/<time>-calls.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
work=${VICTORY_WORK_DIR:-$(dirname -- "$repo")}
data=${VICTORY_RUN_DIR:-$work/victory-run}

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || fail "Run this as yourself, not with sudo. It asks for sudo where it needs it."
perf --version >/dev/null 2>&1 || fail "perf is missing. Install it with:
  sudo apt install linux-tools-$(uname -r)"

pids=$(pgrep -f 'victory\.exe run ' | paste -sd, || true)
[[ -n $pids ]] || fail "The game is not running. Start it and get into the world first."
# the game is the one of these processes that holds the most memory
pid=$(ps -o pid=,rss= -p "$pids" | sort -k2 -nr | awk 'NR == 1 { print $1 }')

out=$data/profiles/$(date +%Y%m%d-%H%M%S)-calls
mkdir -p "$out"
sudo -v

# processor time of each wineserver so far, in clock ticks
server_ticks() {
    local p
    for p in $(pgrep -x wineserver || true); do
        printf '%s %s\n' "$p" "$(awk '{ print $14 + $15 }' "/proc/$p/stat" 2>/dev/null || echo 0)"
    done
}

echo "Measuring for about 20 seconds. Switch back to the game and keep playing."
sleep 5
{ echo "ticks per second: $(getconf CLK_TCK)"; echo "start $(date +%s.%N)"; server_ticks; } >"$out/wineserver.txt"

echo "1/2 counting system calls"
sudo perf trace -s -p "$pid" -o "$out/syscalls.txt" -- sleep 5 ||
    echo "counting failed, carrying on" >&2

echo "2/2 sampling where the kernel time goes"
sudo perf record -F 499 -g -p "$pid" -o "$out/calls.data" -- sleep 12

{ echo "end $(date +%s.%N)"; server_ticks; } >>"$out/wineserver.txt"

echo "Writing the report (this can take a minute)..."
# call chains as names only, without addresses
sudo perf script -i "$out/calls.data" -F comm,tid,period,ip,sym,dso 2>"$out/script.err" |
    sed -E 's/^([[:space:]]+)[0-9a-f]+ /\1/' | gzip >"$out/stacks.txt.gz"

sudo chown "$(id -u):$(id -g)" "$out"/*
chmod 644 "$out"/*

echo "Done: $out"
