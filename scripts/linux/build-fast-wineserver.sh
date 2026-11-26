#!/usr/bin/env bash
# Make a copy of Proton Experimental whose wineserver looks memory views up in a
# tree instead of a list (Wine bug 60868, CachyOS/wine-cachyos pull request 50,
# commit fd66dbc). Your Steam Proton install is only read.
#
# Usage:
#   bash scripts/linux/build-fast-wineserver.sh
#
# Environment overrides:
#   VICTORY_WORK_DIR  Output parent dir for proton-fast/ and wineserver-build/
#                     (default: parent of repo root)
#   VICTORY_RUN_DIR   Runtime dir for prefix-fast (default: <work>/victory-run)
#   PROTON_DIR        Path to Proton Experimental
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
work=${VICTORY_WORK_DIR:-$(dirname -- "$repo")}
data=${VICTORY_RUN_DIR:-$work/victory-run}
proton=${PROTON_DIR:-"$HOME/.steam/steam/steamapps/common/Proton - Experimental"}
copy=$work/proton-fast
partial=$work/proton-fast.partial
build=$work/wineserver-build
patch=$here/wineserver-view-tree.patch.txt
patch_sha=b424692e749c425775e7a47afed752dfab89726abb315ed0e5829a02d4dde585
prefix=$data/prefix-fast

fail() { printf '%s\n' "$*" >&2; exit 1; }

missing=
for tool in git make gcc clang flex bison autoreconf perl python3; do
    command -v "$tool" >/dev/null || missing+=" $tool"
done
[[ -z $missing ]] || fail "Missing:$missing
Run: sudo apt install git build-essential clang flex bison autoconf perl python3"
[[ -f $proton/version && -x $proton/files/bin/wineserver ]] || fail "No Proton at: $proton (set PROTON_DIR)"
printf '%s  %s\n' "$patch_sha" "$patch" | sha256sum --quiet -c - || fail "Patch file missing or changed: $patch"
[[ ! -e $copy ]] || fail "$copy already exists. Move or delete it to build again."
free_gb=$(df -BG --output=avail "$work" | tail -1 | tr -dc 0-9)
((free_gb >= 5)) || fail "Need 5 GB free, have $free_gb GB"

echo "1/5 copying Proton (your install is not changed)"
rm -rf -- "$partial" "$build"
cp -a --reflink=auto -- "$proton" "$partial"

# the copy's version file names the exact Wine source
read -r _ name <"$partial/version"
short=$(sed -nE 's/.*-w([0-9a-f]+)-.*/\1/p' <<<"$name")
[[ $name == experimental-* && -n $short ]] || fail "Unexpected Proton version: $name"
tag=experimental-wine-${name#experimental-}
tag=${tag%-x86_64}

echo "2/5 downloading Wine source for $name"
mkdir -p "$build/src" "$build/obj"
cd "$build/src"
git init -q .
git fetch -q --depth 1 https://github.com/ValveSoftware/wine "refs/tags/$tag" ||
    fail "Could not download Wine tag $tag"
git checkout -q FETCH_HEAD
head=$(git rev-parse HEAD)
[[ $head == "$short"* ]] || fail "Wine tag is at $head, but this Proton was built from $short"
git apply "$patch" || fail "The patch does not fit this Wine source (Proton has changed)"

echo "3/5 configuring"
sh autogen.sh >"$build/autogen.log" 2>&1 || fail "autogen failed, see $build/autogen.log"
cd "$build/obj"
../src/configure --enable-win64 --without-x --without-freetype --without-mingw --disable-tests \
    >"$build/configure.log" 2>&1 || fail "configure failed, see $build/configure.log"

echo "4/5 building wineserver"
make -j"$(nproc)" server/wineserver >"$build/make.log" 2>&1 || fail "build failed, see $build/make.log"
rm -f -- "$partial/files/bin/wineserver"
install -m 755 server/wineserver "$partial/files/bin/wineserver"
cd "$work"
mv -- "$partial" "$copy"

echo "5/5 making its prefix (this also checks that Proton accepts the new wineserver)"
rm -f -- "$prefix.ready"
mkdir -p "$data"
bash "$here/setup-prefix.sh" "$copy" "$prefix" "$copy/files/lib/wine/vkd3d-proton/x86_64-windows" ||
    fail "The new wineserver did not work. Delete $copy and check the messages above."
: >"$prefix.ready"
printf '%s\n' "$name" "wine $head" "patch $patch_sha" >"$copy/patched-wineserver"

echo "Done. scripts/linux/run-victory-lowmem.sh will automatically use $copy."
echo "To run with the standard wineserver again, pass STOCK_WINESERVER=1."
