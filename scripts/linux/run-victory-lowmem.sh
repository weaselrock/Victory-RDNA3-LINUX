#!/usr/bin/env bash
# Build and run VIctory under Proton on Linux (AMD RDNA 3 / Mesa RADV) with
# lower-memory settings, a systemd memory cap, and per-run memory/perf logs.
#
# Usage:
#   D3DCOMPILER_DLL=/path/to/d3dcompiler_47.dll bash scripts/linux/run-victory-lowmem.sh --game-dir /path/to/dump
#   bash scripts/linux/run-victory-lowmem.sh --game-dir /path/to/dump
#   bash scripts/linux/run-victory-lowmem.sh --game-dir /path/to/dump warm [--limit N] [--used] [--jobs N]
#
# Options:
#   --game-dir <dir>   Folder containing game_scarlett_master.exe and package files
#                      (or set GAME_DIR; defaults to <work>/package if present)
#   --exe <path>       Explicit path to game_scarlett_master.exe (optional)
#   -h, --help         Show this help
#
# Environment overrides:
#   GAME_DIR           Same as --game-dir
#   VICTORY_WORK_DIR   Working directory outside the repo for caches, prefix,
#                      proton-fast, and radv (default: parent of repo root)
#   VICTORY_RUN_DIR    Runtime data/cache/prefix/logs dir (default: <work>/victory-run)
#   D3DCOMPILER_DLL    Path to Microsoft's 64-bit d3dcompiler_47.dll (10.0.x, first run)
#   PROTON_DIR         Path to Proton Experimental (default: Steam Proton Experimental)
#   STOCK_WINESERVER=1 Ignore <work>/proton-fast and use stock Proton wineserver
#   SYSTEM_RADV=1      Ignore <work>/radv and use system Mesa RADV
#   SKIP_BUILD=1       Reuse existing target/x86_64-pc-windows-msvc/diag/victory.exe
#   BUILD_PROFILE      Cargo profile: diag (default) or release
#   RAM_MAX            systemd MemoryMax limit (default: 24G)
#   SWAP_MAX           systemd MemorySwapMax limit (default: 24G)
#   VICTORY_*          Any VIctory runtime switch (e.g. VICTORY_MOUSE=1, VICTORY_WINDOW_KB=4096)
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
self=$here/$(basename -- "${BASH_SOURCE[0]}")
src=$(cd -- "$here/../.." && pwd)
work=${VICTORY_WORK_DIR:-$(dirname -- "$src")}
data=${VICTORY_RUN_DIR:-$work/victory-run}

fail() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,28p' "$self" | sed 's/^# \{0,1\}//'
}

inside_scope=0
if [[ ${1:-} == --inside-scope ]]; then
    inside_scope=1
    shift
fi

game_dir=${GAME_DIR:-}
game_exe=${GAME_EXE:-}
pos=()
while (($#)); do
    case $1 in
        --game-dir)
            (($# >= 2)) || fail "Missing argument for --game-dir"
            game_dir=$2
            shift 2
            ;;
        --game-dir=*)
            game_dir=${1#*=}
            shift
            ;;
        --exe)
            (($# >= 2)) || fail "Missing argument for --exe"
            game_exe=$2
            shift 2
            ;;
        --exe=*)
            game_exe=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            pos+=("$@")
            break
            ;;
        *)
            pos+=("$1")
            shift
            ;;
    esac
done
set -- "${pos[@]}"

if [[ -z $game_dir && -n $game_exe ]]; then
    game_dir=$(dirname -- "$game_exe")
fi
if [[ -z $game_dir ]]; then
    game_dir=$work/package
fi
if [[ -d $game_dir ]]; then
    game_dir=$(cd -- "$game_dir" && pwd)
fi
game=${game_exe:-$game_dir/game_scarlett_master.exe}

# a copy with the patched wineserver (build-fast-wineserver.sh) is used when present
fast=$work/proton-fast
proton=${PROTON_DIR:-"$HOME/.steam/steam/steamapps/common/Proton - Experimental"}
if [[ -z ${PROTON_DIR:-} && ${STOCK_WINESERVER:-0} != 1 && -f $fast/patched-wineserver ]]; then
    proton=$fast
fi
files=$proton/files
target=x86_64-pc-windows-msvc
profile=${BUILD_PROFILE:-diag}
exe=$src/target/$target/$profile/victory.exe
prefix=$data/prefix
# each wineserver keeps a prefix of its own
if [[ $proton == "$fast" ]]; then prefix=$data/prefix-fast; fi
dll=$data/d3dcompiler_47.dll

dll_version() {
    python3 -I - "$1" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read()
i = b.find('VS_VERSION_INFO'.encode('utf-16le'))
j = b.find(struct.pack('<I', 0xFEEF04BD), i) if i >= 0 else -1
if b'Wine builtin DLL' in b[:256]:
    print('wine-builtin')
elif j < 0 or struct.unpack_from('<H', b, struct.unpack_from('<I', b, 0x3c)[0] + 4)[0] != 0x8664:
    print('not-a-64-bit-versioned-dll')
else:
    ms, ls = struct.unpack_from('<II', b, j + 8)
    print(f'{ms >> 16}.{ms & 65535}.{ls >> 16}.{ls & 65535}')
EOF
}

if (( ! inside_scope )); then
    case ${1:-} in
        '') ;;
        warm)
            [[ -s $data/cache/pipelines/known-pipelines.bin ]] || fail "Nothing recorded to precompile yet.
Play once with this launcher until you are in the game, quit, then run warm." ;;
        *) fail "Unknown argument: $1 (nothing to play, or: warm [--limit N] [--used] [--jobs N])" ;;
    esac
    # each run ends by stopping every Wine process of the prefix
    ! pgrep -f 'victory\.exe (run|warm)' >/dev/null || fail "VIctory is already running (a game or a warm). Quit it first."
    [[ -d $src ]] || fail "Missing source tree: $src"
    [[ -x $files/bin/wine ]] || fail "No Proton at: $proton (set PROTON_DIR)"
    if [[ ${1:-} != warm ]]; then
        [[ -d $game_dir ]] || fail "Game directory not found: $game_dir
Pass --game-dir /path/to/dump (or set GAME_DIR=/path/to/dump)."
        [[ -e $game ]] || fail "Game executable not found: $game
Pass --game-dir /path/to/dump (containing game_scarlett_master.exe) or --exe /path/to/game_scarlett_master.exe."
    fi
    mkdir -p "$data/cache" "$data/data" "$data/vkd3d-cache" "$data/logs"

    if [[ -n ${D3DCOMPILER_DLL:-} ]]; then
        v=$(dll_version "$D3DCOMPILER_DLL")
        [[ $v == 10.0.* ]] || fail "$D3DCOMPILER_DLL is '$v'; need Microsoft's 64-bit 10.0.x (tested: 10.0.26100)"
        cp -- "$D3DCOMPILER_DLL" "$dll"
    fi
    [[ -f $dll ]] || fail "First run: set D3DCOMPILER_DLL to Microsoft's 64-bit d3dcompiler_47.dll, version 10.0.x.
A Windows 10 or 11 install has it in C:\\Windows\\System32; the Windows SDK has it too.
The copy in a Proton prefix, and the one winetricks installs, do not work."

    if [[ ${SKIP_BUILD:-0} != 1 ]]; then
        command -v cargo-xwin >/dev/null || [[ -x ${CARGO_HOME:-$HOME/.cargo}/bin/cargo-xwin ]] || fail "cargo-xwin is not installed. Run:
  cargo install --locked cargo-xwin
  cd $src && rustup target add $target && rustup component add llvm-tools
cargo-xwin downloads Microsoft's CRT and Windows SDK, under Microsoft's license."
        command -v clang >/dev/null || fail "clang is not installed. Install your distribution's clang, llvm and lld packages."
        if [[ $profile == release ]]; then
            (cd "$src" && cargo xwin build --locked --release -p victory --target "$target")
        else
            (cd "$src" && cargo xwin build --locked --profile "$profile" -p victory --features diagnostics --target "$target")
        fi
    fi
    [[ -f $exe ]] || fail "No $exe (run without SKIP_BUILD=1)"

    printf 'Proton:   %s\n' "$proton"
    printf 'Game dir: %s\n' "$game_dir"
    free_gb=$(df -BG --output=avail "$data" | tail -1 | tr -dc 0-9)
    printf 'Free disk space: %s GB (the shader cache will grow)\n' "$free_gb"

    reexec_args=(--inside-scope --game-dir "$game_dir")
    if [[ -n $game_exe ]]; then
        reexec_args+=(--exe "$game_exe")
    fi
    # the memory limit keeps a run that outgrows the PC from taking the desktop with it
    exec systemd-run --user --scope -p "MemoryMax=${RAM_MAX:-24G}" -p "MemorySwapMax=${SWAP_MAX:-24G}" \
        -- bash "$self" "${reexec_args[@]}" "$@"
fi

export WINEPREFIX=$prefix WINEDEBUG=${WINEDEBUG:--all,err+vulkan}
if [[ ! -f $prefix.ready ]]; then
    bash "$here/setup-prefix.sh" "$proton" "$prefix" "$files/lib/wine/vkd3d-proton/x86_64-windows"
    : >"$prefix.ready"
fi
# never write through a link into the Proton install
cp --remove-destination -- "$dll" "$prefix/drive_c/windows/system32/d3dcompiler_47.dll"
export WINEDLLOVERRIDES='d3d12,d3d12core,dxgi,d3d11,d3d10core=n,b;d3dcompiler_47=n'
export VKD3D_SHADER_CACHE_PATH=$data/vkd3d-cache

# `winepath` once returned nothing for the game; Wine maps Z: to /, so fall back to that
winpath() {
    local w
    w=$("$files/bin/wine" winepath -w "$1" | tr -d '\r') || w=
    [[ -n $w ]] || w=Z:${1//\//\\}
    printf '%s' "$w"
}
VICTORY_GAME_DIR=$(winpath "$game_dir")
VICTORY_CACHE_DIR=$(winpath "$data/cache")
VICTORY_DATA_DIR=$(winpath "$data/data")
export VICTORY_GAME_DIR VICTORY_CACHE_DIR VICTORY_DATA_DIR

setting() { [[ -n ${!1+set} ]] || printf -v "$1" '%s' "$2"; export "$1"; }

# start settings (scripts/play.ps1 -Safe), without DRED notes
setting VICTORY_TEXTURE_NO_WAIT 1
setting VICTORY_RELAY 2
setting VICTORY_WIDE_BACK 1
setting VICTORY_CARD_REHASH_RUNS 1
setting VICTORY_JOIN_COPIES 1
setting VICTORY_INDIRECT_WINDOW 1
setting VICTORY_RELAY_COPY 1
setting VICTORY_CARD_STEPS 2
setting VICTORY_INDIRECT_BATCH 2
setting VICTORY_MAP_THREADS 1
setting VICTORY_TITLE_PRIORITIES 0
setting VICTORY_CARD_AWAKE 1
setting VICTORY_SHOW_AFTER 1
setting VICTORY_AMBIENT 0.8
setting VICTORY_UNDER_WIDE 0
setting VICTORY_LAND_ECHO 0
# lower memory
setting VICTORY_IDLE_LISTS 128      # spare command lists kept (default 512)
setting VICTORY_WINDOW_KB 1024      # grid for copies of title memory (default 4096)
setting VICTORY_MEMORY_MAP 0        # the address-space walk is slow under Wine
# keep a list of the pipelines the game creates, for warm
setting VICTORY_PIPELINE_BOOK 1
# the driver's shader cache on disk holds 1 GB unless told otherwise
setting MESA_SHADER_CACHE_MAX_SIZE 10G

# the driver built by build-radv.sh, for this game only
if [[ ${SYSTEM_RADV:-0} != 1 && -z ${VK_DRIVER_FILES:-} && -f $work/radv/icd-path ]]; then
    VK_DRIVER_FILES=$(<"$work/radv/icd-path")
    [[ -f $VK_DRIVER_FILES ]] || fail "Driver file missing: $VK_DRIVER_FILES (run scripts/linux/build-radv.sh, or set SYSTEM_RADV=1)"
    export VK_DRIVER_FILES VK_ICD_FILENAMES=$VK_DRIVER_FILES
fi

stamp=$(date +%Y%m%d-%H%M%S)
logs=$data/logs/$stamp
mkdir -p "$logs"
env | grep -E '^(VICTORY|VKD3D|WINE|VK_|RADV|MESA)' | sort >"$logs/settings.txt"

cg=/sys/fs/cgroup$(awk -F: '$1 == 0 { print $3 }' /proc/self/cgroup)
sample() {
    echo 'seconds,ram_bytes,swap_bytes'
    local t0=$SECONDS
    while sleep 5; do
        echo "$((SECONDS - t0)),$(cat "$cg/memory.current" 2>/dev/null || echo 0),$(cat "$cg/memory.swap.current" 2>/dev/null || echo 0)"
    done
}
sample >"$logs/memory.csv" &
sampler=$!

finish() {
    trap - EXIT INT TERM
    kill "$sampler" 2>/dev/null || true
    "$files/bin/wineserver" -k 2>/dev/null || true   # this prefix only
    {
        awk -F, 'NR > 1 { if ($2 > r) r = $2; if ($3 > s) s = $3; if ($2 + $3 > t) t = $2 + $3 }
                 END { printf "peak RAM %.1f GiB, peak swap %.1f GiB, peak together %.1f GiB\n", r / 2^30, s / 2^30, t / 2^30 }' "$logs/memory.csv"
        grep -E '^oom' "$cg/memory.events" 2>/dev/null || true
        echo 'last memory lines from VIctory:'
        grep -a -E 'memory(, what holds it)?: ' "$logs/victory.log" 2>/dev/null | tail -n 4 || true
        echo 'graphics driver and descriptor slots:'
        for what in 'Found device: AMD Radeon RX' 'VK_EXT_descriptor_heap enabled' 'host view heaps hold' \
            'host view heap capped' 'GPUVM fault'; do
            grep -a -m1 -F "$what" "$logs/victory.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-220 || true
        done
        printf 'out-of-slots warnings: %s\n' "$(grep -a -c -F 'no free dynamic descriptor slots' "$logs/victory.log" 2>/dev/null || true)"
    } | tee "$logs/summary.txt"
    printf 'Logs: %s\n' "$logs"
}
trap finish EXIT
trap 'exit 130' INT TERM

cd "$data"
if [[ ${1:-} == warm ]]; then
    "$files/bin/wine" "$exe" warm "${@:2}" 2>&1 | tee "$logs/victory.log"
else
    "$files/bin/wine" "$exe" run "$(winpath "$game")" --execute 2>&1 | tee "$logs/victory.log"
fi
