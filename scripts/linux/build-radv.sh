#!/usr/bin/env bash
# Build only the AMD Vulkan driver (RADV) from Mesa 26.3.1 into <work>/radv
# for scripts/linux/run-victory-lowmem.sh to use. Your system graphics driver
# is not touched.
#
# Usage:
#   bash scripts/linux/build-radv.sh
#
# The Mesa release is taken from MESA_TARBALL or ~/Downloads when present,
# else downloaded. Mesa 26.3.1 needs libdrm 2.4.133; where the system's is
# older, meson downloads it and builds it into the driver.
#
# Run one game with the system driver again:  SYSTEM_RADV=1 bash scripts/linux/run-victory-lowmem.sh --game-dir <dir>
# Remove the built driver:                    delete <work>/radv
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
work=${VICTORY_WORK_DIR:-$(dirname -- "$repo")}
root=$work/radv
ver=26.3.1
sha=4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961
name=mesa-$ver
tarball=$root/$name.tar.xz
src=$root/$name
build=$root/build
prefix=$root/install
icd=$prefix/share/vulkan/icd.d/radeon_icd.x86_64.json

fail() { printf '%s\n' "$*" >&2; exit 1; }

# system compiler, python and meson only, whatever the shell has set up
export PATH=/usr/bin:/bin
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR LD_LIBRARY_PATH

[[ $(uname -m) == x86_64 ]] || fail "This script builds the 64-bit x86 driver only."
[[ -d $work ]] || fail "Missing $work"

packages=(
    meson ninja-build pkgconf gcc g++ glslang-tools
    python3-mako python3-yaml python3-packaging
    libx11-dev libx11-xcb-dev libxcb1-dev libxcb-randr0-dev libxcb-dri3-dev
    libxcb-present-dev libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev
    libxshmfence-dev libxcb-keysyms1-dev libexpat1-dev zlib1g-dev libzstd-dev
    vulkan-tools curl ca-certificates xz-utils
)
if command -v dpkg-query >/dev/null 2>&1; then
    missing=()
    for p in "${packages[@]}"; do
        [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]] || missing+=("$p")
    done
    if ((${#missing[@]})); then
        printf 'Install the build packages, then run this again:\n\n  sudo apt install %s\n\n' "${missing[*]}" >&2
        exit 1
    fi
fi

free_gb=$(df -BG --output=avail "$work" | tail -1 | tr -dc 0-9)
((free_gb >= 4)) || fail "Need 4 GB free under $work, have ${free_gb} GB."

mkdir -p "$root"
if [[ ! -f $tarball ]]; then
    if [[ -n ${MESA_TARBALL:-} ]]; then
        cp -- "$MESA_TARBALL" "$tarball.part"
    elif [[ -f $HOME/Downloads/$name.tar.xz ]]; then
        cp -- "$HOME/Downloads/$name.tar.xz" "$tarball.part"
    else
        curl -fL --retry 3 -o "$tarball.part" "https://archive.mesa3d.org/$name.tar.xz"
    fi
    mv -- "$tarball.part" "$tarball"
fi
printf '%s  %s\n' "$sha" "$tarball" | sha256sum -c --quiet - ||
    fail "Checksum mismatch. Delete $tarball and run this again."

if [[ ! -f $src.unpacked ]]; then
    rm -rf -- "$src" "$build"
    tar -xf "$tarball" -C "$root"
    : >"$src.unpacked"
fi

if [[ ! -f $build/build.ninja ]]; then
    rm -rf -- "$build"
    meson setup "$build" "$src" \
        --prefix="$prefix" --libdir=lib --buildtype=release \
        -Dvulkan-drivers=amd -Dgallium-drivers= -Dplatforms=x11 \
        -Dllvm=disabled -Dopengl=false -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dgles1=disabled -Dgles2=disabled -Dvulkan-layers= -Dvideo-codecs= \
        -Dxlib-lease=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
        -Dallow-fallback-for=libdrm -Dlibdrm:default_library=static
fi
ninja -C "$build"
meson install -C "$build" --quiet

[[ -f $icd ]] || fail "The install has no $icd"
unresolved=$(ldd "$prefix/lib/libvulkan_radeon.so" | grep 'not found' || true)
[[ -z $unresolved ]] || fail "The driver is missing libraries:
$unresolved"

info=$(VK_DRIVER_FILES=$icd VK_ICD_FILENAMES=$icd vulkaninfo 2>"$root/vulkaninfo.err" || true)
grep -q "Mesa $ver" <<<"$info" ||
    fail "The built driver did not load as Mesa $ver. See $root/vulkaninfo.err"
grep -q 'VK_EXT_descriptor_heap' <<<"$info" ||
    fail "The built driver loaded but does not offer VK_EXT_descriptor_heap."
printf '%s\n' "$icd" >"$root/icd-path"
grep -E 'deviceName|driverInfo' <<<"$info" | sort -u

cat <<EOF

Driver ready. Every shader compiles again with it, so warm the caches first
(graphics can be wrong in this run):

  VICTORY_COMPUTE_WAIT=0 SKIP_BUILD=1 bash $here/run-victory-lowmem.sh --game-dir /path/to/dump

Quit once you have been in the 3D world for a few minutes, then run normally:

  SKIP_BUILD=1 bash $here/run-victory-lowmem.sh --game-dir /path/to/dump
EOF
