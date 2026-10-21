#!/bin/bash
# Builds "This iPad" Linux for PadCode:
#   ios/Generated/LinuxKernel.xcframework  the iSH kernel (vendor/ish, arm64 guest)
#                                          plus vendor/ish-shim, as module PadLinux
#   ios/Generated/linux-root               Alpine 3.21 (aarch64) as a fakefs root,
#                                          with python3 and ripgrep
#
#   ./build-linux.sh            libraries; the root only if it's missing
#   ./build-linux.sh --rootfs   rebuild the root too (downloads packages)
#
# Needs a venv with meson, ninja and ziglang (zig's clang+lld build the vdso, an
# aarch64 Linux ELF that Apple's linker can't make):
#   python3 -m venv ~/Documents/tools/padcode-buildenv
#   ~/Documents/tools/padcode-buildenv/bin/pip install meson ninja ziglang
set -euo pipefail
cd "$(dirname "$0")"
TOP=$PWD
B=$TOP/build/linux
OUT=$TOP/ios/Generated
VENV=${PADCODE_BUILDENV:-$HOME/Documents/tools/padcode-buildenv}
ALPINE=3.21.8
ALPINE_URL=https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-$ALPINE-aarch64.tar.gz
ALPINE_SHA256=f25a96d2846a4bc439093107c1b48a8b0c93dcb411e2cb9cfded6f790b2bc001
# Headers for macOS's own libarchive (fakefsify); the SDK has the library only.
LIBARCHIVE_TAG=v3.7.4
PACKAGES="python3 ripgrep"

[ -x "$VENV/bin/meson" ] || { echo "missing $VENV (see the top of $0)" >&2; exit 1; }
export PATH="$VENV/bin:$PATH"
mkdir -p "$B/include" "$B/dl" "$OUT"

cat > "$B/vdso-cc" <<EOF
#!/bin/sh
# aarch64 Linux ELF compiler for the vdso: zig cc (it always links with lld).
for a in "\$@"; do case "\$a" in -fuse-ld=*) ;; *) set -- "\$@" "\$a" ;; esac; shift; done
exec "$VENV/bin/python" -m ziglang cc "\$@"
EOF
chmod +x "$B/vdso-cc"
for h in archive.h archive_entry.h; do
    [ -f "$B/include/$h" ] ||
        curl -fsSL "https://raw.githubusercontent.com/libarchive/libarchive/$LIBARCHIVE_TAG/libarchive/$h" -o "$B/include/$h"
done

setup() { # build dir, extra meson options...
    local dir=$1; shift
    [ -f "$dir/build.ninja" ] ||
        meson setup "$dir" vendor/ish -Dguest_arch=arm64 -Djit=false -Dbuildtype=release -Dvdso_cc="$B/vdso-cc" "$@"
}

# 1. The Mac's own CLI and fakefsify, to make the root filesystem.
setup "$B/host" -Dlibarchive_include="$B/include"
ninja -C "$B/host" ish tools/fakefsify

# 2. The root filesystem.
if [ "${1:-}" = --rootfs ] || [ ! -f "$OUT/linux-root/meta.db" ]; then
    tgz=$B/dl/alpine-minirootfs-$ALPINE-aarch64.tar.gz
    [ -f "$tgz" ] || curl -fsSL "$ALPINE_URL" -o "$tgz"
    echo "$ALPINE_SHA256  $tgz" | shasum -a 256 -c -
    stage=$B/root-stage
    rm -rf "$stage"
    "$B/host/tools/fakefsify" "$tgz" "$stage"
    guest() { "$B/host/ish" -f "$stage" "$@"; }
    guest /bin/sh -c 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf'
    guest /sbin/apk add --no-cache $PACKAGES
    guest /bin/sh -s < vendor/ish-shim/provision.sh
    # One self-contained database file (no -wal/-shm) to ship.
    sqlite3 "$stage/meta.db" 'PRAGMA wal_checkpoint(TRUNCATE);' > /dev/null
    rm -f "$stage/meta.db-wal" "$stage/meta.db-shm"
    rm -rf "$OUT/linux-root"
    mv "$stage" "$OUT/linux-root"
    echo "linux-root: $(du -sh "$OUT/linux-root" | cut -f1)"
fi

# 3. The kernel for the iPad and the Simulator, plus the shim, as one library each.
libs=()
for plat in iphoneos iphonesimulator; do
    sdk=$(xcrun --sdk $plat --show-sdk-path)
    target=arm64-apple-ios17.0
    [ $plat = iphonesimulator ] && target=$target-simulator
    cat > "$B/cross-$plat.txt" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$plat', 'clang']
ar = ['xcrun', '--sdk', '$plat', 'ar']

[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sdk']
c_link_args = ['-target', '$target', '-isysroot', '$sdk']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
    dir=$B/$plat
    setup "$dir" --cross-file "$B/cross-$plat.txt" -Dlog_handler=nslog
    ninja -C "$dir" libish.a libish_emu.a libfakefs.a
    # The shim, compiled exactly like the kernel's own kernel/init.c.
    (cd "$dir" && eval "$(python3 - "$TOP/vendor/ish-shim/padlinux.c" <<'PY'
import json, shlex, sys
cmd = next(c for c in json.load(open('compile_commands.json')) if c['file'].endswith('kernel/init.c'))
args = shlex.split(cmd['command'])
out, skip = [], 0
for a in args:
    if skip: skip -= 1; continue
    if a in ('-o', '-MQ', '-MF'): skip = 1; continue
    if a in ('-c', '-MD') or a.endswith('kernel/init.c'): continue
    out.append(a)
print(shlex.join(out + ['-I', sys.argv[1].rsplit('/', 1)[0], '-c', sys.argv[1], '-o', 'padlinux.o']))
PY
)")
    libtool -static -o "$dir/libpadlinux.a" "$dir/libish.a" "$dir/libish_emu.a" "$dir/libfakefs.a" "$dir/padlinux.o" 2>/dev/null
    libs+=(-library "$dir/libpadlinux.a" -headers "$B/headers")
done

# In a PadLinux/ subfolder: Xcode copies every xcframework's headers into one
# include/ dir, and PadCoreFFI's module.modulemap already sits at its top.
rm -rf "$B/headers"
mkdir -p "$B/headers/PadLinux"
cp vendor/ish-shim/padlinux.h vendor/ish-shim/module.modulemap "$B/headers/PadLinux/"
rm -rf "$OUT/LinuxKernel.xcframework"
xcodebuild -create-xcframework "${libs[@]}" -output "$OUT/LinuxKernel.xcframework" > /dev/null
echo "built $OUT/LinuxKernel.xcframework (link with -lsqlite3 -lresolv)"
