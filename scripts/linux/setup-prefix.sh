#!/usr/bin/env bash
# Make a Wine prefix for VIctory under Proton: Proton's libvkd3d, DXVK's
# DXGI/D3D11/D3D10Core, and vkd3d-proton's D3D12 DLLs.
#
# Usage:
#   bash scripts/linux/setup-prefix.sh <proton-dir> <prefix> <vkd3d-proton-dir>
#
# Only <prefix> is written to.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <proton-dir> <prefix> <vkd3d-proton-dir>" >&2
    exit 2
fi
proton=$1
vkd3d=$3
files=$proton/files
[ -x "$files/bin/wine" ] || files=$proton   # a bare "files" folder works too
[ -x "$files/bin/wine" ] || { echo "no files/bin/wine in $proton" >&2; exit 1; }
for f in d3d12.dll d3d12core.dll; do
    [ -f "$vkd3d/$f" ] || { echo "no $f in $vkd3d" >&2; exit 1; }
done
mkdir -p "$2"
prefix=$(cd "$2" && pwd)

export WINEPREFIX=$prefix WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml="   # no Mono / Gecko download prompts
"$files/bin/wine" wineboot --init
"$files/bin/wineserver" --wait

sys32=$prefix/drive_c/windows/system32
[ -d "$sys32" ] || { echo "wineboot did not create $sys32" >&2; exit 1; }

cp "$files"/lib/vkd3d/x86_64-windows/libvkd3d-*.dll "$sys32/"
for f in dxgi.dll d3d11.dll d3d10core.dll; do
    cp "$files/lib/wine/dxvk/x86_64-windows/$f" "$sys32/"
done
cp "$vkd3d/d3d12.dll" "$vkd3d/d3d12core.dll" "$sys32/"

"$files/bin/wineserver" --kill 2>/dev/null || true
echo "prefix ready: $prefix"
