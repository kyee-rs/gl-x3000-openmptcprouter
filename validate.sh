#!/usr/bin/env bash
set -Eeuo pipefail

readonly KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest.lock
source "$KIT_DIR/manifest.lock"

readonly OMR_DIR="${1:-/work/openmptcprouter}"
readonly OMR_FEED_DIR="${2:-/work/openmptcprouter-feed}"
readonly SOURCE_ROOT="$OMR_DIR/gl-x3000/6.18/source"

fail() {
    printf 'VALIDATION ERROR: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

require_config() {
    grep -Fqx -- "$1" "$SOURCE_ROOT/.config" || fail "missing config: $1"
}

require_string() {
    local file="$1"
    local expected="$2"
    grep -Fqx -- "$expected" < <(strings "$file") \
        || fail "missing '$expected' in $(basename -- "$file")"
}

check_revision() {
    local repository="$1"
    local expected="$2"
    local label="$3"
    local actual

    [[ -d "$repository/.git" ]] || fail "$label repository is missing: $repository"
    actual="$(git -C "$repository" rev-parse HEAD)"
    [[ "$actual" == "$expected" ]] || fail "$label revision is $actual, expected $expected"
}

for command_name in git grep strings find fdtget sha256sum tar cmp awk 7z mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

require_file "$SOURCE_ROOT/.config"
check_revision "$OMR_DIR" "$OMR_COMMIT" OMR
check_revision "$OMR_FEED_DIR" "$OMR_FEED_COMMIT" OMR-feed
check_revision "$SOURCE_ROOT" "$OPENWRT_COMMIT" OpenWrt
check_revision "$OMR_DIR/feeds/6.18/packages" "$OPENWRT_PACKAGES_COMMIT" OpenWrt-packages
check_revision "$OMR_DIR/feeds/6.18/luci" "$OPENWRT_LUCI_COMMIT" OpenWrt-LuCI
check_revision "$OMR_DIR/feeds/6.18/routing" "$OPENWRT_ROUTING_COMMIT" OpenWrt-routing

require_config 'CONFIG_PACKAGE_kmod-mhi-bus=y'
require_config 'CONFIG_PACKAGE_kmod-mhi-pci-generic=y'
require_config '# CONFIG_PACKAGE_kmod-mhi-net is not set'
require_config 'CONFIG_PACKAGE_kmod-mhi-wwan-ctrl=y'
require_config 'CONFIG_PACKAGE_kmod-mhi-wwan-mbim=y'
require_config 'CONFIG_PACKAGE_modemmanager=y'
require_config 'CONFIG_MODEMMANAGER_WITH_NETIFD=y'
require_config 'CONFIG_MODEMMANAGER_WITH_MBIM=y'

readonly KERNEL_PATCH="$OMR_DIR/6.18/target/linux/generic/pending-6.18/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch"
readonly DTS_SOURCE="$OMR_DIR/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts"
readonly MM_PATCH="$OMR_FEED_DIR/modemmanager/patches/010-broadband-modem-mbim-handle-mhi-pci-generic.patch"
readonly OWNER_GUARD="$OMR_DIR/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner"
require_file "$KERNEL_PATCH"
require_file "$DTS_SOURCE"
require_file "$MM_PATCH"
require_file "$OWNER_GUARD"
[[ -x "$OWNER_GUARD" ]] || fail 'cellular ownership guard is not executable'
cmp -s "$KERNEL_PATCH" "$KIT_DIR/patches/kernel/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch" \
    || fail 'kernel patch differs from the audited build-kit copy'
cmp -s "$DTS_SOURCE" "$KIT_DIR/overlays/openmptcprouter/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts" \
    || fail 'GL-X3000 DTS differs from the audited build-kit copy'
cmp -s "$MM_PATCH" "$KIT_DIR/patches/modemmanager/010-broadband-modem-mbim-handle-mhi-pci-generic.patch" \
    || fail 'ModemManager patch differs from the audited build-kit copy'
cmp -s "$OWNER_GUARD" "$KIT_DIR/overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner" \
    || fail 'cellular ownership guard differs from the audited build-kit copy'
grep -Fqx 'LINUX_VERSION-6.18 = .34' "$SOURCE_ROOT/target/linux/generic/kernel-6.18" \
    || fail 'unexpected Linux 6.18 point release'
grep -Fqx 'PKG_RELEASE:=5' "$OMR_FEED_DIR/modemmanager/Makefile" \
    || fail 'ModemManager package release was not bumped for the backport'
grep -Fq 'mhi_quectel_rm5xx_info' "$KERNEL_PATCH" || fail 'kernel patch does not select the upstream Quectel profile'
grep -Fq 'PCI_DEVICE_SUB(PCI_VENDOR_ID_QCOM, 0x0308, PCI_VENDOR_ID_QCOM, 0x5201)' "$KERNEL_PATCH" || fail 'kernel patch has the wrong PCI subsystem match'
grep -Fq 'bootargs-append = " pcie_port_pm=off";' "$DTS_SOURCE" || fail 'DTS lacks early PCIe port-PM disable'
grep -Fq "$MODEMMANAGER_BACKPORT" "$MM_PATCH" || fail 'ModemManager backport provenance is missing'
grep -Fq 'https://packages.openmptcprouter.com/${OMR_RELEASE}-${OMR_KERNEL}/${OMR_REAL_TARGET}/luci/packages.adb' "$OMR_DIR/build.sh" \
    || fail 'OMR build script lacks versioned HTTPS APK feeds'

mapfile -t dtbs < <(find "$SOURCE_ROOT/build_dir" -type f -name 'image-mt7981a-glinet-gl-x3000.dtb' -print | sort)
[[ "${#dtbs[@]}" -gt 0 ]] || fail 'compiled GL-X3000 DTB not found'
readonly dtb="${dtbs[0]}"
readonly bootargs_append="$(fdtget "$dtb" /chosen bootargs-append)"
[[ "$bootargs_append" == ' pcie_port_pm=off' ]] || fail "unexpected bootargs-append: $bootargs_append"

mapfile -t mhi_modules < <(find "$SOURCE_ROOT/build_dir" -type f \
    -path '*/root-mediatek/lib/modules/*/mhi_pci_generic.ko' -print | sort)
[[ "${#mhi_modules[@]}" -gt 0 ]] || fail 'installed mhi_pci_generic.ko not found'
readonly mhi_module="${mhi_modules[0]}"
require_string "$mhi_module" quectel-rm5xx
require_string "$mhi_module" IP_HW0_MBIM
grep -Fq 'pci:v000017CBd00000308sv000017CBsd00005201' < <(strings "$mhi_module") \
    || fail 'RM520N GL-X3000 PCI alias is absent'
if grep -Fqx 'qcom-sdx65m-rm520-mbim' < <(strings "$mhi_module"); then
    fail 'experimental hybrid MHI profile is present'
fi
if [[ -n "$(find "$SOURCE_ROOT/build_dir" -type f \
    -path '*/root-mediatek/lib/modules/*/mhi_net.ko' -print -quit)" ]]; then
    fail 'mhi_net.ko was installed despite the MBIM-only target config'
fi

mapfile -t mbim_modules < <(find "$SOURCE_ROOT/build_dir" -type f \
    -path '*/root-mediatek/lib/modules/*/mhi_wwan_mbim.ko' -print | sort)
[[ "${#mbim_modules[@]}" -gt 0 ]] || fail 'installed mhi_wwan_mbim.ko not found'

mapfile -t mm_binaries < <(find "$SOURCE_ROOT/build_dir" -type f \
    -path '*/root-mediatek/usr/sbin/ModemManager' -print | sort)
[[ "${#mm_binaries[@]}" -gt 0 ]] || fail 'installed ModemManager binary not found'
require_string "${mm_binaries[0]}" mhi-pci-generic

readonly TARGET_BIN_DIR="$SOURCE_ROOT/bin/targets/mediatek/filogic"
mapfile -t images < <(find "$TARGET_BIN_DIR" -maxdepth 1 -type f \
    -name '*glinet_gl-x3000*squashfs-sysupgrade.bin' -print | sort)
[[ "${#images[@]}" -eq 1 ]] || fail "expected one GL-X3000 sysupgrade image, found ${#images[@]}"
grep -Fqx sysupgrade-glinet_gl-x3000/CONTROL < <(tar -tf "${images[0]}") \
    || fail 'sysupgrade archive lacks the GL-X3000 control entry'

readonly root_audit="$(mktemp -d /tmp/gl-x3000-root.XXXXXX)"
tar -xOf "${images[0]}" sysupgrade-glinet_gl-x3000/root > "$root_audit/root.squashfs"
7z x -y -o"$root_audit/rootfs" "$root_audit/root.squashfs" >/dev/null 2>&1 || true
readonly distfeeds="$root_audit/rootfs/etc/apk/repositories.d/distfeeds.list"
readonly customfeeds="$root_audit/rootfs/etc/apk/repositories.d/customfeeds.list"
readonly installed_guard="$root_audit/rootfs/etc/uci-defaults/99-cellular-control-owner"
require_file "$distfeeds"
require_file "$customfeeds"
require_file "$installed_guard"
grep -Fqx "https://download.openmptcprouter.com/release/${OMR_RELEASE}-${OMR_KERNEL}/${OMR_TARGET}/targets/mediatek/filogic/packages/packages.adb" "$distfeeds" \
    || fail 'target package feed is not the public version-matched HTTPS endpoint'
for repository in luci packages base routing telephony; do
    grep -Fqx "https://packages.openmptcprouter.com/${OMR_RELEASE}-${OMR_KERNEL}/aarch64_cortex-a53/${repository}/packages.adb" "$customfeeds" \
        || fail "missing public ${repository} APK feed"
done
if grep -Eq '^http://' "$distfeeds" "$customfeeds"; then
    fail 'plaintext package repository URL is embedded in the image'
fi
grep -Fq "proto='mbim'" "$installed_guard" || fail 'ownership guard lacks native-MBIM detection'
grep -Fq 'modemmanager disable' "$installed_guard" || fail 'ownership guard does not disable ModemManager'

printf 'OMR=%s\n' "$OMR_COMMIT"
printf 'OMR_FEED=%s\n' "$OMR_FEED_COMMIT"
printf 'OPENWRT=%s\n' "$OPENWRT_COMMIT"
printf 'KERNEL=%s\n' "$LINUX_VERSION"
printf 'MODEMMANAGER=%s+%s\n' "$MODEMMANAGER_VERSION" "$MODEMMANAGER_BACKPORT"
printf 'IMAGE_SHA256='
sha256sum "${images[0]}" | awk '{print $1}'
printf 'VALIDATION=passed\n'
