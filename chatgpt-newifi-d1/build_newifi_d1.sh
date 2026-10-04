#!/usr/bin/env bash
set -euo pipefail

LEDE_COMMIT="41728362433b239f2927ef76ed1527bd9e5010af"
OPENCLASH_TAG="v0.47.116"
OPENCLASH_COMMIT="23896d2662a7d49fa870d37c5cda4b3247a35ae4"
WORK="${GITHUB_WORKSPACE:-$PWD}/newifi-d1-build"
OUT="${GITHUB_WORKSPACE:-$PWD}/newifi-d1-output"
JOBS="$(nproc)"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "== Clone LEDE exact 2024-05 baseline =="
git init lede
cd lede
git remote add origin https://github.com/coolsnowwolf/lede.git
git fetch --depth=1 origin "$LEDE_COMMIT"
git checkout --detach FETCH_HEAD
printf '%s\n' "$LEDE_COMMIT" > "$OUT/LEDE_COMMIT.txt"

# Sanity: this exact revision is the one reported by the user's existing firmware.
test "$(git rev-parse HEAD)" = "$LEDE_COMMIT"

cd "$WORK"
echo "== Clone OpenClash pinned tag =="
git init OpenClash
git -C OpenClash remote add origin https://github.com/vernesong/OpenClash.git
git -C OpenClash fetch --depth=1 origin "refs/tags/${OPENCLASH_TAG}:refs/tags/${OPENCLASH_TAG}"
git -C OpenClash checkout --detach "$OPENCLASH_TAG"
test "$(git -C OpenClash rev-parse HEAD)" = "$OPENCLASH_COMMIT"
printf '%s %s\n' "$OPENCLASH_TAG" "$OPENCLASH_COMMIT" > "$OUT/OPENCLASH_VERSION.txt"

cd "$WORK/lede"

echo "== Update/install feeds =="
./scripts/feeds update -a
./scripts/feeds install -a
rm -rf package/luci-app-openclash
cp -a "$WORK/OpenClash/luci-app-openclash" package/luci-app-openclash

mkdir -p files/etc/init.d files/etc/uci-defaults files/usr/share/openclash-lowmem

cat > files/etc/init.d/openclash_swap <<'EOF'
#!/bin/sh /etc/rc.common
START=90
STOP=10

SWAP_MOUNT="/mnt/mmcblk0p1"
SWAP_FILE="$SWAP_MOUNT/openclash.swap"
SWAP_MB=512

start() {
    local i=0
    while [ "$i" -lt 30 ]; do
        grep -qs " $SWAP_MOUNT " /proc/mounts && break
        sleep 1
        i=$((i + 1))
    done
    if ! grep -qs " $SWAP_MOUNT " /proc/mounts; then
        logger -t openclash_swap "SD mount unavailable; refusing to create swap on flash"
        return 0
    fi
    if [ ! -f "$SWAP_FILE" ]; then
        logger -t openclash_swap "Creating ${SWAP_MB}MiB swap on SD"
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" 2>/dev/null || return 1
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null 2>&1 || return 1
    fi
    grep -Fq "$SWAP_FILE" /proc/swaps || swapon "$SWAP_FILE"
    echo 60 > /proc/sys/vm/swappiness
    logger -t openclash_swap "Swap ready; swappiness=60"
}

stop() {
    grep -Fq "$SWAP_FILE" /proc/swaps && swapoff "$SWAP_FILE"
}
EOF
chmod 0755 files/etc/init.d/openclash_swap

cat > files/etc/init.d/openclash_core_stage <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=11

SD_MOUNT="/mnt/mmcblk0p1"
SD_CORE="$SD_MOUNT/openclash/core/clash_meta"
RAM_DIR="/tmp/etc/openclash/core"
RAM_CORE="$RAM_DIR/clash_meta"

start() {
    local i=0
    mkdir -p "$RAM_DIR"
    rm -f "$RAM_CORE"
    while [ "$i" -lt 30 ]; do
        grep -qs " $SD_MOUNT " /proc/mounts && break
        sleep 1
        i=$((i + 1))
    done
    if ! grep -qs " $SD_MOUNT " /proc/mounts; then
        logger -t openclash_core_stage "SD unavailable; Smart core will be downloaded to RAM only if OpenClash starts"
        return 0
    fi
    mkdir -p "$SD_MOUNT/openclash/core"
    if [ -s "$SD_CORE" ]; then
        cp -f "$SD_CORE" "$RAM_CORE.tmp" || return 1
        chmod 4755 "$RAM_CORE.tmp"
        mv -f "$RAM_CORE.tmp" "$RAM_CORE"
        logger -t openclash_core_stage "Core staged SD -> RAM ($(wc -c < "$RAM_CORE") bytes)"
    else
        logger -t openclash_core_stage "No persistent core on SD; OpenClash may download one into RAM"
    fi
}

stop() {
    rm -f "$RAM_CORE" "$RAM_CORE.tmp"
}
EOF
chmod 0755 files/etc/init.d/openclash_core_stage

cat > files/etc/uci-defaults/99-openclash-lowmem <<'EOF'
#!/bin/sh
/etc/init.d/openclash_swap enable
/etc/init.d/openclash_core_stage enable
uci -q set openclash.config.small_flash_memory='1'
uci -q set openclash.config.ipv6_enable='0'
uci -q set openclash.config.ipv6_dns='0'
uci -q commit openclash
exit 0
EOF
chmod 0755 files/etc/uci-defaults/99-openclash-lowmem

cat > files/usr/share/openclash-lowmem/README <<'EOF'
Newifi D1 low-memory layout:
  persistent Smart/Meta core: /mnt/mmcblk0p1/openclash/core/clash_meta
  runtime core:              /tmp/etc/openclash/core/clash_meta
  SD swap:                   /mnt/mmcblk0p1/openclash.swap (512MiB)
Flash must not store a 60MiB core under /etc/openclash/core.
EOF

# Patch OpenClash for low-memory operation and SD persistence.
python3 - <<'PY'
from pathlib import Path
import re

pkg = Path('package/luci-app-openclash')
controller_candidates = [pkg/'luasrc/controller/openclash.lua', pkg/'luasrc/controller/openclash.lua']
debug = pkg/'root/usr/share/openclash/openclash_debug.sh'
core = pkg/'root/usr/share/openclash/openclash_core.sh'
report=[]

controller = next((p for p in controller_candidates if p.exists()), None)
if controller:
    s=controller.read_text(errors='surrogateescape')
    # Disable only the LuCI display-only Mihomo version spawn.
    patterns=[
        r'v\s*=\s*SYS\.exec\(string\.format\("%s -v[^\n]*meta_core_path\)\)',
        r'v\s*=\s*SYS\.exec\(string\.format\([^\n]*meta_core_path[^\n]*\)\)'
    ]
    n_total=0
    for pat in patterns:
        s2,n=re.subn(pat, 'v = "unknown" -- Newifi D1 low-memory: avoid second Mihomo process for version display', s, count=1)
        if n:
            s=s2; n_total+=n; break
    if n_total:
        controller.write_text(s, errors='surrogateescape')
        report.append(f'controller version probe patched: {n_total}')
    else:
        report.append('controller version probe pattern not present; no patch applied')

if debug.exists():
    s=debug.read_text(errors='surrogateescape')
    pats=[
        r'^\s*core_meta_version=\$\([^\n]*clash_meta[^\n]*-v[^\n]*\)\s*$',
        r'^\s*core_meta_version=\$\([^\n]*-v[^\n]*\)\s*$'
    ]
    n_total=0
    for pat in pats:
        s2,n=re.subn(pat, 'core_meta_version="unknown" # Newifi D1 low-memory: avoid second Mihomo process', s, count=1, flags=re.M)
        if n:
            s=s2; n_total+=n; break
    if n_total:
        debug.write_text(s, errors='surrogateescape')
        report.append(f'debug version probe patched: {n_total}')
    else:
        report.append('debug version probe pattern not present; no patch applied')

if not core.exists():
    raise SystemExit('ERROR: openclash_core.sh missing')
s=core.read_text(errors='surrogateescape')
marker='''               if [ "$?" == "0" ]; then\n                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful!"'''
insert='''               if [ "$?" == "0" ]; then\n                  # Newifi D1 small-flash mode: persist the successfully validated RAM core to SD.\n                  if [ "$small_flash_memory" = "1" ] && grep -qs " /mnt/mmcblk0p1 " /proc/mounts; then\n                     mkdir -p /mnt/mmcblk0p1/openclash/core >/dev/null 2>&1\n                     cp -f "$TARGET_CORE_PATH" /mnt/mmcblk0p1/openclash/core/clash_meta.tmp >/dev/null 2>&1 && \\\n                     chmod 4755 /mnt/mmcblk0p1/openclash/core/clash_meta.tmp >/dev/null 2>&1 && \\\n                     mv -f /mnt/mmcblk0p1/openclash/core/clash_meta.tmp /mnt/mmcblk0p1/openclash/core/clash_meta >/dev/null 2>&1\n                  fi\n                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful!"'''
if marker not in s:
    raise SystemExit('ERROR: OpenClash core-update success marker not found')
s=s.replace(marker, insert, 1)
core.write_text(s, errors='surrogateescape')
report.append('core updater patched: validated RAM core persists to SD')

Path('NEWIFI_LOW_MEMORY_PATCH_REPORT.txt').write_text('\n'.join(report)+'\n')
print('\n'.join(report))
PY
cp NEWIFI_LOW_MEMORY_PATCH_REPORT.txt "$OUT/"

# Configuration: exact Newifi D1 target, LuCI, PPPoE, OpenClash iptables path, SD/ext4.
cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_lenovo_newifi-d1=y
CONFIG_TARGET_ROOTFS_SQUASHFS=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_ppp=y
CONFIG_PACKAGE_ppp-mod-pppoe=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_iptables=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_iptables-mod-tproxy=y
CONFIG_PACKAGE_kmod-ipt-ipset=y
CONFIG_PACKAGE_kmod-ipt-tproxy=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_ruby=y
CONFIG_PACKAGE_ruby-yaml=y
CONFIG_PACKAGE_unzip=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-mmc=y
CONFIG_PACKAGE_kmod-sdhci-mt7620=y
EOF

make defconfig

# Explicitly strip services that consumed flash in the previous image and are not required.
for p in \
  zerotier luci-app-zerotier luci-app-ssr-plus xray-core \
  frpc luci-app-frpc vlmcsd luci-app-vlmcsd vsftpd-alt luci-app-vsftpd \
  samba36-server luci-app-samba simple-obfs-client; do
  ./scripts/config --disable "PACKAGE_${p}" || true
done
make defconfig

cp .config "$OUT/final.config"

echo "== Critical config =="
grep -E 'TARGET_ramips|newifi|openclash|dnsmasq-full|pppoe|ruby|ext4|sdhci|zerotier|ssr|xray|frpc' .config | tee "$OUT/config-summary.txt"

echo "== Download sources =="
make download -j"$JOBS" V=s

echo "== Build =="
# First parallel attempt; retry serially with verbose output for a useful failure log.
set +e
make -j"$JOBS" V=s 2>&1 | tee "$OUT/build.log"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  echo "Parallel build failed; retrying serial verbose" | tee -a "$OUT/build.log"
  make -j1 V=s 2>&1 | tee "$OUT/build-serial.log"
fi

echo "== Collect image =="
mapfile -t imgs < <(find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*lenovo_newifi-d1*squashfs*sysupgrade.bin' -o -name '*newifi-d1*squashfs*sysupgrade.bin' | sort)
if [ "${#imgs[@]}" -eq 0 ]; then
  find bin/targets/ramips/mt7621 -maxdepth 1 -type f -print | sort | tee "$OUT/target-files.txt"
  echo "ERROR: Newifi D1 sysupgrade image not found" >&2
  exit 1
fi
IMG="${imgs[0]}"
cp "$IMG" "$OUT/newifi-d1-openclash-optimized-squashfs-sysupgrade.bin"

# Validation.
FINAL="$OUT/newifi-d1-openclash-optimized-squashfs-sysupgrade.bin"
SIZE=$(stat -c %s "$FINAL")
LIMIT=$((0x01fb0000))
{
  echo "LEDE_COMMIT=$LEDE_COMMIT"
  echo "OPENCLASH_TAG=$OPENCLASH_TAG"
  echo "OPENCLASH_COMMIT=$OPENCLASH_COMMIT"
  echo "IMAGE=$FINAL"
  echo "SIZE=$SIZE"
  echo "FIRMWARE_MTD_LIMIT=$LIMIT"
  sha256sum "$FINAL"
  file "$FINAL"
} | tee "$OUT/IMAGE_VALIDATION.txt"
[ "$SIZE" -le "$LIMIT" ] || { echo "ERROR: image exceeds firmware partition" | tee -a "$OUT/IMAGE_VALIDATION.txt"; exit 1; }

echo "== Verify rootfs staging tree ==" | tee -a "$OUT/IMAGE_VALIDATION.txt"
for f in \
  files/etc/init.d/openclash_swap \
  files/etc/init.d/openclash_core_stage \
  files/etc/uci-defaults/99-openclash-lowmem; do
  test -s "$f" || { echo "MISSING: $f"; exit 1; }
  echo "OK: $f" | tee -a "$OUT/IMAGE_VALIDATION.txt"
done
# Ensure no prebundled giant core was added by our build overlay/package.
if find files package/luci-app-openclash -type f -path '*/etc/openclash/core/*' -size +5M | grep -q .; then
  echo "ERROR: giant core found in flash staging inputs" | tee -a "$OUT/IMAGE_VALIDATION.txt"
  exit 1
fi
echo "PASS: no giant Smart/Meta core bundled in flash staging inputs" | tee -a "$OUT/IMAGE_VALIDATION.txt"

grep -n 'small_flash_memory' files/etc/uci-defaults/99-openclash-lowmem | tee -a "$OUT/IMAGE_VALIDATION.txt"
grep -n 'START=' files/etc/init.d/openclash_swap files/etc/init.d/openclash_core_stage package/luci-app-openclash/root/etc/init.d/openclash | tee -a "$OUT/IMAGE_VALIDATION.txt" || true

# Copy build metadata if present.
cp -a bin/targets/ramips/mt7621/sha256sums "$OUT/" 2>/dev/null || true
cp -a bin/targets/ramips/mt7621/profiles.json "$OUT/" 2>/dev/null || true

echo "BUILD COMPLETE"
ls -lh "$OUT"
