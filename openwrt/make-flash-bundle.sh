#!/bin/bash
# Build the flash package for other people's E5s:
# out/openwrt/e5-openwrt-flash-<version>-<timestamp>-<git>.tar.gz, unpacked and run as
# ./flash.sh (openwrt/bundle/README.md is its manual).
#
#   openwrt/make-flash-bundle.sh
#   E5_MAINLINE=1 openwrt/make-flash-bundle.sh    the mainline 6.18 kernel instead of 5.15:
#       e5-openwrt-flash-<version>-mainline-<timestamp>-<git>; the kernel of E5_RELEASE=1 upstream/build.sh
#       (upstream/out-release: no e5.openwrt=, so it is no trial), the boot modules of
#       upstream/module-order.txt, and an image rebuilt with upstream/root-modules.txt in it
#   E5_IMAGE_FROM=<openwrt.ext4.gz> (with E5_MAINLINE=1)   no image rebuilt (build-rootfs.sh needs docker):
#       that one, a flash package's files/openwrt.ext4.gz, with this kernel's root modules written in
#       (openwrt/image-add-modules.sh) -- only for an image whose sources did not change since
#
# What goes in, and what does not:
#
#  * the generic OpenWrt image (openwrt/build-rootfs.sh with E5_STANDALONE=1
#    E5_DEVICE_FILES=0, built here when out/openwrt has none): none of this
#    device's files -- no vendor firmware, no Android vendor subset, which are
#    proprietary and carry the unit's identity (BT address, serial number);
#  * a boot image without the Debian overlay (boot/build-boot-image.py with no
#    --overlay): the overlay is Debian's, and holds this device's firmware,
#    MAC addresses and hotspot profile;
#  * the flasher, flash.py (Python: Windows, macOS, Linux; flash.cmd and
#    flash.sh start it), which pulls the recipient's own firmware off their
#    Android and converts it (tools/sprd-bt-config.py, vbc-profile), and has
#    the vendor subset collected and packed on the device itself
#    (bundle/collect-device-files.sh) -- some of those files have ":" in their
#    names, which Windows cannot store; boot/init unpacks the archive into the
#    image at boot (e5linux/device-files.tar);
#  * the device-side installers for updates over the USB LAN.
#
# Both images are checked for the files that must not be there before the
# package is written.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
VER=${E5_WRT_VER:-25.12.5}
OUT="$TOP/out/openwrt"
WORK="$TOP/work/openwrt"
IMG="$OUT/e5-openwrt-$VER-generic.ext4.gz"
KERNEL=${E5_KERNEL:-$TOP/work/Image-bt2}
STOCK_BOOT=${E5_STOCK_BOOT:-$TOP/dumps/boot_b.img}
MISC_HEAD=${E5_MISC_HEAD:-$TOP/dumps/misc-head.bin}
BUSYBOX=${E5_BUSYBOX:-$TOP/work/busybox/ext/usr/bin/busybox}
python3 - "$TOP" "$BUSYBOX" <<'PY'
from pathlib import Path
import runpy, sys
runpy.run_path(str(Path(sys.argv[1]) / 'openwrt/bundle/flash.py'))['validate_installer_busybox'](sys.argv[2])
PY
GIT=$(git -C "$TOP" describe --always --dirty 2>/dev/null || echo dev)
# CI sets the epoch before compiling; local builds capture the package start.
# POSIX TZ uses the opposite sign: CST-8 is fixed UTC+8, without daylight saving.
E5_BUILD_EPOCH=${E5_BUILD_EPOCH:-$(date +%s)}
export E5_BUILD_EPOCH
read -r STAMP BUILD_TIME < <(python3 - "$E5_BUILD_EPOCH" <<'PY'
from datetime import datetime, timedelta, timezone
import sys
t = datetime.fromtimestamp(int(sys.argv[1]), timezone(timedelta(hours=8)))
print(t.strftime('%Y%m%d-%H%M%S'), t.isoformat(timespec='seconds'))
PY
)
NAME=e5-openwrt-flash-$VER-$STAMP-$GIT
MAINLINE=${E5_MAINLINE:-}
KOUT=${E5_UPSTREAM_OUT:-$TOP/upstream/out-release}
if [ -n "$MAINLINE" ]; then
    NAME=e5-openwrt-flash-$VER-mainline-$STAMP-$GIT
    KERNEL=$KOUT/Image.lk
    [ -f "$KERNEL" ] || { echo "no $KERNEL: E5_RELEASE=1 upstream/build.sh" >&2; exit 1; }
    # (grep -c, not grep -q: see the kernel check below)
    [ "$(strings "$KERNEL" | grep -c 'e5\.openwrt=' || true)" = 0 ] ||
        { echo "$KERNEL has e5.openwrt= on its command line: a trial kernel" >&2; exit 1; }
    E5_UPSTREAM_OUT=$KOUT sh "$TOP/upstream/root-modules.sh"
    if [ -n "${E5_IMAGE_FROM:-}" ]; then
        bash "$HERE/image-add-modules.sh" "$E5_IMAGE_FROM" "$KOUT/root-modules.tar" "$IMG"
    else
        # the image always again: it has to carry this kernel's root modules
        E5_ROOT_MODULES=$KOUT/root-modules.tar E5_ROOT_MODULES_ONLY=1 \
            E5_STANDALONE=1 E5_DEVICE_FILES=0 bash "$HERE/build-rootfs.sh"
    fi
elif [ ! -f "$IMG" ] || [ -n "${E5_REBUILD:-}" ]; then
    E5_STANDALONE=1 E5_DEVICE_FILES=0 bash "$HERE/build-rootfs.sh"
fi
echo "== checking the image for device files"
S0=$(mktemp -d)
trap 'rm -rf "$S0"' EXIT
if [ -n "${E5_IMAGE_FROM:-}" ]; then
    # The supplied image has no rootfs tarball; inspect its extracted tree.
    gzip -dc "$IMG" > "$S0/img"
    mkdir "$S0/root"
    debugfs -R "rdump / $S0/root" "$S0/img" >/dev/null 2>&1
    image_source="$S0/root"
else
    image_source="$WORK/e5-openwrt-$VER-generic-rootfs.tar.gz"
fi
python3 - "$image_source" <<'PY'
import os
import re
import shlex
import stat
import sys
import tarfile

source = sys.argv[1]
if os.path.isdir(source):
    def walk_error(error):
        raise error

    def entries():
        for root, dirs, files in os.walk(source, followlinks=False, onerror=walk_error):
            for name in dirs + files:
                path = os.path.join(root, name)
                mode = os.lstat(path).st_mode
                name = os.path.relpath(path, source).replace(os.sep, '/')
                data = None
                if name == 'etc/config/attendedsysupgrade' and stat.S_ISREG(mode) and not mode & 0o111:
                    with open(path, 'rb') as f:
                        data = f.read(1024 * 1024 + 1)
                yield name, mode, data
else:
    def entries():
        with tarfile.open(source, 'r:gz') as archive:
            for member in archive:
                mode = member.mode | (stat.S_IFREG if member.isfile() else 0)
                data = None
                if member.name in ('etc/config/attendedsysupgrade', './etc/config/attendedsysupgrade') and member.isfile() and not mode & 0o111:
                    with archive.extractfile(member) as f:
                        data = f.read(1024 * 1024 + 1)
                # tar -t prints a trailing slash for directories.
                yield member.name + ('/' if member.isdir() else ''), mode, data

def disabled_config(data):
    # Accept ordinary UCI directives only, failing closed on ambiguous input.
    if data is None or len(data) > 1024 * 1024:
        return False
    section = None
    clients = 0
    values = []
    identifier = re.compile(r'^[A-Za-z0-9_]+$')
    try:
        for line in data.decode('utf-8').splitlines():
            fields = shlex.split(line, comments=True)
            if not fields:
                continue
            if fields[0] == 'config' and len(fields) in (2, 3):
                if not all(identifier.fullmatch(s) for s in fields[1:]):
                    return False
                section = fields[2] if len(fields) == 3 else ''
                if section == 'client':
                    clients += 1
                    if fields[1] != 'client':
                        return False
            elif fields[0] in ('option', 'list') and len(fields) == 3 and section is not None:
                if not identifier.fullmatch(fields[1]):
                    return False
                if section == 'client' and fields[1] == 'login_check_for_upgrades':
                    values.append((fields[0], fields[2]))
            else:
                return False
    except (UnicodeDecodeError, ValueError):
        return False
    return clients == 1 and values == [('option', '0')]


forbidden = re.compile(r'lib/firmware/(wcnmodem|gnssmodem|l_agdsp|wifi_board|sprd/)|opt/e5/android/.|etc/e5/install\.conf|mnt/vendor/.')
config = ('etc/config/attendedsysupgrade', './etc/config/attendedsysupgrade')
found_init = False
config_count = 0
bad = []
for name, mode, data in entries():
    found_init |= name in ('sbin/init', './sbin/init')
    is_config = name in config
    if is_config:
        config_count += 1
    if forbidden.search(name) or ('attendedsysupgrade' in name and not (
            is_config and stat.S_ISREG(mode) and not mode & 0o111 and disabled_config(data))):
        bad.append(name)
if not found_init:
    sys.exit('no listing of the image')
if config_count > 1:
    bad.append('duplicate etc/config/attendedsysupgrade')
if bad:
    print('the generic image carries what it must not (device files, attended sysupgrade):', file=sys.stderr)
    for name in bad[:10]:
        print(repr(name), file=sys.stderr)
    sys.exit(1)
PY

echo "== boot image without the overlay"
BOOT="$TOP/work/boot-linux-slotb-bundle"
if [ -n "$MAINLINE" ]; then
    # (the kernel's command line is its own, CONFIG_CMDLINE_FORCE: upstream/make-boot.sh)
    BOOT="$TOP/work/boot-linux-slotb-bundle-mainline"
    python3 "$TOP/boot/build-boot-image.py" --stock-boot "$STOCK_BOOT" \
        --misc-head "$MISC_HEAD" --kernel "$KERNEL" --modules "$KOUT/modules" \
        --module-order "$TOP/upstream/module-order.txt" --cmdline "" \
        --busybox "$BUSYBOX" --out "$BOOT.img" | tail -1
else
    python3 "$TOP/boot/build-boot-image.py" --stock-boot "$STOCK_BOOT" \
        --misc-head "$MISC_HEAD" --kernel "$KERNEL" --modules "$TOP/out_modules" \
        --busybox "$BUSYBOX" --out "$BOOT.img" | tail -1
fi
[ "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['overlay_files'])" "$BOOT.json")" = 0 ] ||
    { echo "the boot image has an overlay" >&2; exit 1; }
# the kernel and the image's modem modules have to be one build
if [ -z "$MAINLINE" ]; then
    rel=$(strings "$TOP/out_linux/drivers/net/wwan/wwan.ko" | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -1)
else
    rel=$(cat "$KOUT/kernel.release")
    grep -qx "lib/modules/$rel/modem/sipc_wwan.ko" < <(tar -tf "$KOUT/root-modules.tar") ||
        { echo "$KOUT/root-modules.tar is not of $rel" >&2; exit 1; }
fi
# (not "strings | grep -q": grep leaves early, and pipefail counts the SIGPIPE)
grep -q "Linux version $rel " < <(strings "$KERNEL") ||
    { echo "the kernel ($KERNEL) is not the build of out_linux ($rel)" >&2; exit 1; }

S=$(mktemp -d)
trap 'rm -rf "$S0" "$S"' EXIT
P=$S/$NAME
mkdir -p "$P/files" "$P/scripts/tools"
cp "$BUSYBOX" "$P/files/busybox"
chmod 0755 "$P/files/busybox"
if [ -n "$MAINLINE" ]; then
    python3 "$TOP/upstream/check-container-support.py" "$KOUT"
    cp "$KOUT/config" "$P/files/kernel.config"
    cp "$KOUT/modules.in-tree" "$P/files/modules.in-tree"
fi
# Use the same descriptive user entries as all three profile packages.
python3 "$HERE/bundle/install-entrypoints.py" "$P"
cp "$HERE/bundle/part-write.sh" "$P/files/"
test -f "$OUT/ext4-tools.tar" || { echo 'Missing ext4-tools.tar: openwrt/prepare-ext4-tools.py --root CLEAN_ARM64_ROOT --out out/openwrt/ext4-tools.tar' >&2; exit 1; }
tar -tf "$OUT/ext4-tools.tar" | grep -qx 'ext4-geometry.sh' || {
    echo 'ext4-tools.tar is stale: rebuild it with openwrt/prepare-ext4-tools.py before packaging' >&2; exit 1;
}
cp "$OUT/ext4-tools.tar" "$P/files/"
test -f "$OUT/install-lock-tools.tar" || { echo 'Missing install-lock-tools.tar: prepare-ext4-tools.py --root CLEAN_ARM64_ROOT --lock-addon-from out/openwrt/ext4-tools.tar --out out/openwrt/install-lock-tools.tar' >&2; exit 1; }
cp "$OUT/install-lock-tools.tar" "$P/files/"
cp "$TOP/LICENSE" "$P/docs/LICENSE"
cp "$IMG" "$P/files/openwrt.ext4.gz"
cp "$BOOT.img" "$P/files/boot.img"
cp "$BOOT.json" "$P/files/boot.json"
cp "$BOOT.misc-slot-b-trial.bin" "$P/files/boot-misc-slot-b.bin"
cp "$HERE/device-install-image.sh" "$HERE/device-install-part.sh" "$HERE/device-flash-boot.sh" "$HERE/device-stage-part-update.sh" "$HERE/bundle/collect-device-files.sh" \
   "$TOP/boot/storage.sh" "$HERE/overlay/usr/libexec/e5-gpt" "$P/files/"
cp "$TOP/openwrt/luci-app-t551m/root/usr/lib/e5/nv_persistence.py" "$P/files/nv-persistence.py"
cp "$TOP/tools/e5-telnet.py" "$TOP/tools/e5-update.py" "$TOP/tools/sprd-bt-config.py" "$P/scripts/tools/"
cp "$TOP/tools/android-bootchain.sh" "$P/files/android-bootchain.sh"
cp -R "$TOP/tools/vbc-profile" "$P/scripts/tools/"
find "$P" \( -name .DS_Store -o -name __pycache__ \) -prune -exec rm -rf {} +
printf "e5-openwrt-flash %s (OpenWrt %s, e5-linux %s, kernel %s)\n" \
    "$BUILD_TIME" "$VER" "$GIT" "$rel" > "$P/files/VERSION"

# One ZIP, usable both from Magisk and after extraction on a computer. Keep
# the native E5 TF partition/update layout and share the same compressed image.
docker run --rm --platform linux/arm64 --user "$(id -u):$(id -g)" -v "$P/files":/out \
    -v "$TOP/magisk/e5-linux-switch/bootctl.c":/src.c:ro \
    "${E5_MAGISK_BUILD_IMAGE:-e5-mainline-build}" \
    sh -ec 'gcc -static -Os -s -Wall -Wextra -Werror -o /out/e5-bootctl /src.c'
if [ ! -O "$P/files/e5-bootctl" ]; then
    echo 'make-flash-bundle: e5-bootctl must belong to the packaging user' >&2
    exit 1
fi
printf '%s\n' '{"profile":"e5","android_models":["E5"]}' > "$P/files/device-profile.json"
python3 "$HERE/bundle/finalize-package.py" "$P" --profile e5 --bootctl "$P/files/e5-bootctl"

# macOS tar otherwise adds AppleDouble files that are absent from the ZIP.
COPYFILE_DISABLE=1 tar -C "$S" -czf "$OUT/$NAME.tar.gz.part" "$NAME"
mv "$OUT/$NAME.tar.gz.part" "$OUT/$NAME.tar.gz"
# and a .zip for Windows (its Explorer opens it without anything installed)
rm -f "$OUT/$NAME.zip"
python3 "$HERE/bundle/finalize-package.py" "$P" --zip-only "$OUT/$NAME.zip.part"
mv "$OUT/$NAME.zip.part" "$OUT/$NAME.zip"
echo "== $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1)), $OUT/$NAME.zip ($(du -h "$OUT/$NAME.zip" | cut -f1))"
