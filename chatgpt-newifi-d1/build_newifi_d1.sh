#!/usr/bin/env bash
set -euo pipefail

LEDE_COMMIT="41728362433b239f2927ef76ed1527bd9e5010af"
PACKAGES_COMMIT="990d29c54025d2f4d9c5a36e9e02469a5ee0498b"
LUCI_COMMIT="ede57a8a186533201bfad1936ca0001e9fc10acb"
ROUTING_COMMIT="3aefda75aee96b485713ba12a8c4e37d76e00095"
OPENCLASH_TAG="v0.47.116"
OPENCLASH_COMMIT="23896d2662a7d49fa870d37c5cda4b3247a35ae4"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
WORK="$ROOT/newifi-d1-build"
LEDE="$WORK/lede"
OC="$WORK/OpenClash"
OUT="$ROOT/newifi-d1-output"
STATE="$WORK/.checkpoints"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$WORK" "$OUT" "$STATE"

stamp() {
  local n="$1"
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE/$n.ready"
  {
    echo "stage=$n"
    echo "time=$(cat "$STATE/$n.ready")"
    echo "lede=$LEDE_COMMIT"
    echo "packages=$PACKAGES_COMMIT"
    echo "luci=$LUCI_COMMIT"
    echo "routing=$ROUTING_COMMIT"
    echo "openclash=$OPENCLASH_TAG/$OPENCLASH_COMMIT"
  } > "$OUT/CHECKPOINT_LAST.txt"
}

has_stamp() { [ -f "$STATE/$1.ready" ]; }

run_make_stage() {
  local stage="$1"; shift
  if has_stamp "$stage"; then
    echo "[$stage] checkpoint found; skip"
    return 0
  fi
  local logfile="$OUT/${stage}.log"
  local seriallog="$OUT/${stage}-serial.log"
  cd "$LEDE"
  set +e
  make -j"$JOBS" V=s "$@" 2>&1 | tee "$logfile"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "[$stage] parallel build failed rc=$rc; retrying serial verbose" | tee -a "$logfile"
    set +e
    make -j1 V=s "$@" 2>&1 | tee "$seriallog"
    rc=${PIPESTATUS[0]}
    set -e
  fi
  if [ "$rc" -ne 0 ]; then
    echo "$rc" > "$STATE/$stage.failed"
    return "$rc"
  fi
  rm -f "$STATE/$stage.failed"
  stamp "$stage"
}

prepare() {
  if has_stamp prepare && [ -d "$LEDE/.git" ] && [ -d "$OC/.git" ]; then
    echo "[prepare] checkpoint found; skip"
    return 0
  fi
  rm -rf "$LEDE" "$OC"
  mkdir -p "$WORK" "$OUT" "$STATE"

  echo "== Clone LEDE pinned baseline =="
  git init "$LEDE"
  git -C "$LEDE" remote add origin https://github.com/coolsnowwolf/lede.git
  git -C "$LEDE" fetch --depth=1 origin "$LEDE_COMMIT"
  git -C "$LEDE" checkout --detach FETCH_HEAD
  test "$(git -C "$LEDE" rev-parse HEAD)" = "$LEDE_COMMIT"

  echo "== Clone OpenClash pinned tag =="
  git init "$OC"
  git -C "$OC" remote add origin https://github.com/vernesong/OpenClash.git
  git -C "$OC" fetch --depth=1 origin "refs/tags/${OPENCLASH_TAG}:refs/tags/${OPENCLASH_TAG}"
  git -C "$OC" checkout --detach "$OPENCLASH_TAG"
  test "$(git -C "$OC" rev-parse HEAD)" = "$OPENCLASH_COMMIT"

  cd "$LEDE"
  cat > feeds.conf <<FEEDS
src-git packages https://github.com/coolsnowwolf/packages^${PACKAGES_COMMIT}
src-git luci https://github.com/coolsnowwolf/luci^${LUCI_COMMIT}
src-git routing https://github.com/coolsnowwolf/routing^${ROUTING_COMMIT}
FEEDS

  echo "== Update/install pinned feeds =="
  ./scripts/feeds update -a
  test "$(git -C feeds/packages rev-parse HEAD)" = "$PACKAGES_COMMIT"
  test "$(git -C feeds/luci rev-parse HEAD)" = "$LUCI_COMMIT"
  test "$(git -C feeds/routing rev-parse HEAD)" = "$ROUTING_COMMIT"
  ./scripts/feeds install -a

  rm -rf package/luci-app-openclash
  cp -a "$OC/luci-app-openclash" package/luci-app-openclash

  mkdir -p files/etc/init.d files/etc/uci-defaults files/usr/share/openclash-lowmem

  cat > files/etc/init.d/openclash_swap <<'EOS'
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
        sleep 1; i=$((i + 1))
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
stop() { grep -Fq "$SWAP_FILE" /proc/swaps && swapoff "$SWAP_FILE"; }
EOS
  chmod 0755 files/etc/init.d/openclash_swap

  cat > files/etc/init.d/openclash_core_stage <<'EOS'
#!/bin/sh /etc/rc.common
START=95
STOP=11
SD_MOUNT="/mnt/mmcblk0p1"
SD_CORE="$SD_MOUNT/openclash/core/clash_meta"
RAM_DIR="/tmp/etc/openclash/core"
RAM_CORE="$RAM_DIR/clash_meta"
start() {
    local i=0
    mkdir -p "$RAM_DIR"; rm -f "$RAM_CORE" "$RAM_CORE.tmp"
    while [ "$i" -lt 30 ]; do
        grep -qs " $SD_MOUNT " /proc/mounts && break
        sleep 1; i=$((i + 1))
    done
    if ! grep -qs " $SD_MOUNT " /proc/mounts; then
        logger -t openclash_core_stage "SD unavailable; keep runtime core in RAM only"
        return 0
    fi
    mkdir -p "$SD_MOUNT/openclash/core"
    if [ -s "$SD_CORE" ]; then
        cp -f "$SD_CORE" "$RAM_CORE.tmp" || return 1
        chmod 4755 "$RAM_CORE.tmp"
        mv -f "$RAM_CORE.tmp" "$RAM_CORE"
        logger -t openclash_core_stage "Core staged SD -> RAM ($(wc -c < "$RAM_CORE") bytes)"
    else
        logger -t openclash_core_stage "No persistent core on SD; OpenClash may download into RAM"
    fi
}
stop() { rm -f "$RAM_CORE" "$RAM_CORE.tmp"; }
EOS
  chmod 0755 files/etc/init.d/openclash_core_stage

  cat > files/etc/uci-defaults/99-openclash-lowmem <<'EOS'
#!/bin/sh
/etc/init.d/openclash_swap enable
/etc/init.d/openclash_core_stage enable
uci -q set openclash.config.small_flash_memory='1'
uci -q set openclash.config.ipv6_enable='0'
uci -q set openclash.config.ipv6_dns='0'
uci -q commit openclash
exit 0
EOS
  chmod 0755 files/etc/uci-defaults/99-openclash-lowmem

  cat > files/usr/share/openclash-lowmem/README <<'EOS'
Newifi D1 low-memory layout:
 persistent core: /mnt/mmcblk0p1/openclash/core/clash_meta
 runtime core:    /tmp/etc/openclash/core/clash_meta
 SD swap:         /mnt/mmcblk0p1/openclash.swap (512MiB)
A 60MiB Smart/Meta core must never be persisted in flash overlay.
EOS

  python3 - <<'PY'
from pathlib import Path
import re
pkg=Path('package/luci-app-openclash')
debug=pkg/'root/usr/share/openclash/openclash_debug.sh'
core=pkg/'root/usr/share/openclash/openclash_core.sh'
report=[]
if debug.exists():
    s=debug.read_text(errors='surrogateescape')
    s2,n=re.subn(r'^\s*core_meta_version=\$\([^\n]*-v[^\n]*\)\s*$', 'core_meta_version="unknown" # Newifi D1: avoid extra Mihomo version process', s, count=1, flags=re.M)
    if n: debug.write_text(s2, errors='surrogateescape')
    report.append(f'debug version probe patched: {n}')
if not core.exists(): raise SystemExit('openclash_core.sh missing')
s=core.read_text(errors='surrogateescape')
marker='''               if [ "$?" == "0" ]; then\n                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful!"'''
insert='''               if [ "$?" == "0" ]; then\n                  # Newifi D1: in small-flash mode persist validated RAM core to SD.\n                  if [ "$small_flash_memory" = "1" ] && grep -qs " /mnt/mmcblk0p1 " /proc/mounts; then\n                     mkdir -p /mnt/mmcblk0p1/openclash/core >/dev/null 2>&1\n                     cp -f "$TARGET_CORE_PATH" /mnt/mmcblk0p1/openclash/core/clash_meta.tmp >/dev/null 2>&1 && \\
                     chmod 4755 /mnt/mmcblk0p1/openclash/core/clash_meta.tmp >/dev/null 2>&1 && \\
                     mv -f /mnt/mmcblk0p1/openclash/core/clash_meta.tmp /mnt/mmcblk0p1/openclash/core/clash_meta >/dev/null 2>&1\n                  fi\n                  LOG_TIP "【"$CORE_TYPE"】Core Update Successful!"'''
if marker not in s: raise SystemExit('OpenClash core update success marker not found')
core.write_text(s.replace(marker,insert,1),errors='surrogateescape')
report.append('core updater patched: RAM core persists to SD')
Path('NEWIFI_LOW_MEMORY_PATCH_REPORT.txt').write_text('\n'.join(report)+'\n')
PY
  cp NEWIFI_LOW_MEMORY_PATCH_REPORT.txt "$OUT/"

  cat > .config <<'CFG'
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
CFG
  make defconfig
  for p in zerotier luci-app-zerotier luci-app-ssr-plus xray-core frpc luci-app-frpc vlmcsd luci-app-vlmcsd vsftpd-alt luci-app-vsftpd samba36-server luci-app-samba simple-obfs-client; do
    ./scripts/config --disable "PACKAGE_${p}" || true
  done
  make defconfig

  cp .config "$OUT/final.config"
  {
    echo "LEDE_COMMIT=$LEDE_COMMIT"
    echo "PACKAGES_COMMIT=$PACKAGES_COMMIT"
    echo "LUCI_COMMIT=$LUCI_COMMIT"
    echo "ROUTING_COMMIT=$ROUTING_COMMIT"
    echo "OPENCLASH_TAG=$OPENCLASH_TAG"
    echo "OPENCLASH_COMMIT=$OPENCLASH_COMMIT"
    echo "KERNEL_EXPECTED=5.4.275"
  } > "$OUT/SOURCE_LOCK.txt"
  grep -E 'TARGET_ramips|newifi|openclash|dnsmasq-full|pppoe|ruby|ext4|sdhci|zerotier|ssr|xray|frpc' .config > "$OUT/config-summary.txt" || true
  stamp prepare
}

download() {
  has_stamp download && { echo "[download] checkpoint found; skip"; return 0; }
  cd "$LEDE"
  make download -j"$JOBS" V=s 2>&1 | tee "$OUT/download.log"
  stamp download
}

toolchain() {
  has_stamp toolchain && { echo "[toolchain] checkpoint found; skip"; return 0; }
  run_make_stage tools tools/install
  run_make_stage toolchain toolchain/install
}

target() {
  has_stamp target && { echo "[target] checkpoint found; skip"; return 0; }
  run_make_stage target target/compile
}

packages() {
  has_stamp packages && { echo "[packages] checkpoint found; skip"; return 0; }
  run_make_stage packages package/compile
}

world() {
  has_stamp world && { echo "[world] checkpoint found; skip"; return 0; }
  run_make_stage world world
}

verify() {
  cd "$LEDE"
  mkdir -p "$OUT"
  mapfile -t imgs < <(find bin/targets/ramips/mt7621 -maxdepth 1 -type f \( -name '*lenovo_newifi-d1*squashfs*sysupgrade.bin' -o -name '*newifi-d1*squashfs*sysupgrade.bin' \) | sort)
  if [ "${#imgs[@]}" -eq 0 ]; then
    find bin/targets/ramips/mt7621 -maxdepth 1 -type f -print | sort > "$OUT/target-files.txt" 2>/dev/null || true
    echo "ERROR: Newifi D1 sysupgrade image not found" >&2
    return 1
  fi
  cp "${imgs[0]}" "$OUT/newifi-d1-openclash-optimized-squashfs-sysupgrade.bin"
  FINAL="$OUT/newifi-d1-openclash-optimized-squashfs-sysupgrade.bin"
  SIZE=$(stat -c %s "$FINAL")
  LIMIT=$((0x01fb0000))
  {
    cat "$OUT/SOURCE_LOCK.txt"
    echo "SIZE=$SIZE"
    echo "FIRMWARE_MTD_LIMIT=$LIMIT"
    sha256sum "$FINAL"
    file "$FINAL"
  } > "$OUT/IMAGE_VALIDATION.txt"
  [ "$SIZE" -le "$LIMIT" ] || { echo "ERROR=image_exceeds_firmware_partition" >> "$OUT/IMAGE_VALIDATION.txt"; return 1; }

  for f in files/etc/init.d/openclash_swap files/etc/init.d/openclash_core_stage files/etc/uci-defaults/99-openclash-lowmem; do
    test -s "$f" || { echo "MISSING=$f" >> "$OUT/IMAGE_VALIDATION.txt"; return 1; }
    echo "OK=$f" >> "$OUT/IMAGE_VALIDATION.txt"
  done
  if find files package/luci-app-openclash -type f -path '*/etc/openclash/core/*' -size +5M | grep -q .; then
    echo "ERROR=giant_core_bundled_in_flash_inputs" >> "$OUT/IMAGE_VALIDATION.txt"
    return 1
  fi
  echo "PASS=no_giant_core_in_flash_inputs" >> "$OUT/IMAGE_VALIDATION.txt"
  grep -n 'small_flash_memory' files/etc/uci-defaults/99-openclash-lowmem >> "$OUT/IMAGE_VALIDATION.txt" || return 1
  grep -n 'START=' files/etc/init.d/openclash_swap files/etc/init.d/openclash_core_stage package/luci-app-openclash/root/etc/init.d/openclash >> "$OUT/IMAGE_VALIDATION.txt" || true
  cp -a bin/targets/ramips/mt7621/sha256sums "$OUT/" 2>/dev/null || true
  cp -a bin/targets/ramips/mt7621/profiles.json "$OUT/" 2>/dev/null || true
  stamp verify
  ls -lh "$OUT"
}

case "${1:-all}" in
  prepare) prepare ;;
  download) download ;;
  toolchain) toolchain ;;
  target) target ;;
  packages) packages ;;
  world) world ;;
  verify) verify ;;
  all) prepare; download; toolchain; target; packages; world; verify ;;
  *) echo "Usage: $0 {prepare|download|toolchain|target|packages|world|verify|all}" >&2; exit 2 ;;
esac
