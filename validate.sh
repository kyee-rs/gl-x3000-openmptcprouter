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

require_tracker_restart_policy() {
    awk '
        index($0, "elif [ \"$mm_state\" = \"enabled\" ] || [ \"$mm_state\" = \"connected\" ]; then") {
            getline
            if ($0 ~ /^[[:space:]]*:[[:space:]]*$/) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$1" || fail "tracker still bypasses restart_down policy: $1"
    grep -Fq 'if [ "$(uci -q get mqvpn.settings.enable)" = "1" ] && [ "$(pgrep mqvpn)" = "" ]; then' "$1" \
        || fail "tracker still restarts a running MQVPN process: $1"
}

test_explicit_mqvpn_error_noop() {
    local hook="$1"
    local test_dir
    test_dir="$(mktemp -d /tmp/mqvpn-explicit-path.XXXXXX)"
    mkdir -p "$test_dir/bin"

    cat >"$test_dir/bin/uci" <<'EOF'
#!/bin/sh
case "$3" in
    mqvpn.settings.enable) printf '1\n' ;;
    mqvpn.multipath.auto_wan) printf '0\n' ;;
    *) exit 1 ;;
esac
EOF
    cat >"$test_dir/bin/pgrep" <<'EOF'
#!/bin/sh
printf '123\n'
EOF
    cat >"$test_dir/bin/mqvpn-path" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MQVPN_TEST_CALLS"
EOF
    chmod +x "$test_dir/bin/uci" "$test_dir/bin/pgrep" "$test_dir/bin/mqvpn-path"

    PATH="$test_dir/bin:$PATH" \
        MQVPN_TEST_CALLS="$test_dir/calls" \
        OMR_TRACKER_STATUS=ERROR \
        OMR_TRACKER_PREV_STATUS=OK \
        OMR_TRACKER_DEVICE=wwan0 \
        OMR_TRACKER_INTERFACE=wan2 \
        /bin/sh "$hook"

    [[ ! -e "$test_dir/calls" ]] \
        || fail "explicit MQVPN path was touched on a tracker error: $hook"
    rm -rf "$test_dir"
}

test_dead_mqvpn_backup_not_selected() {
    local hook="$1"
    local test_dir
    test_dir="$(mktemp -d /tmp/mqvpn-dead-backup.XXXXXX)"
    mkdir -p "$test_dir/bin" "$test_dir/lib"

    cat >"$test_dir/lib/common-post-tracking.sh" <<'EOF'
_log() { :; }
EOF
    cat >"$test_dir/bin/ifstatus" <<'EOF'
#!/bin/sh
printf '{"up":true}\n'
EOF
    cat >"$test_dir/bin/jsonfilter" <<'EOF'
#!/bin/sh
printf 'true\n'
EOF
    cat >"$test_dir/bin/uci" <<'EOF'
#!/bin/sh
case "$3" in
    mqvpn.settings.enable) printf '1\n' ;;
    mqvpn.multipath.auto_wan) printf '0\n' ;;
    mqvpn.multipath.path) printf 'eth0 wwan0\n' ;;
    mqvpn.server.ip) printf '198.51.100.10\n' ;;
    *) exit 1 ;;
esac
EOF
    cat >"$test_dir/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MQVPN_TEST_CALLS"
case "$*" in
    '-4 route show default dev wwan0')
        printf 'default via 198.51.100.1 dev wwan0 metric 5\n'
        ;;
esac
EOF
    cat >"$test_dir/bin/ping" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$test_dir/bin/ifstatus" "$test_dir/bin/jsonfilter" \
        "$test_dir/bin/uci" "$test_dir/bin/ip" "$test_dir/bin/ping"

    PATH="$test_dir/bin:$PATH" \
        MQVPN_TEST_CALLS="$test_dir/calls" \
        OMR_LIB_DIR="$test_dir/lib" \
        OMR_TRACKER_STATUS=ERROR \
        OMR_TRACKER_PREV_STATUS=OK \
        OMR_TRACKER_DEVICE=eth0 \
        OMR_TRACKER_INTERFACE=wan1 \
        /bin/sh "$hook"

    if grep -Fq 'route replace' "$test_dir/calls"; then
        fail "tracker redirected the VPS route through an unreachable backup: $hook"
    fi
    rm -rf "$test_dir"
}

require_string() {
    local file="$1"
    local expected="$2"
    grep -Fqx -- "$expected" < <(strings "$file") \
        || fail "missing '$expected' in $(basename -- "$file")"
}

require_substring() {
    local file="$1"
    local expected="$2"
    grep -Fq -- "$expected" < <(strings "$file") \
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

for command_name in git grep strings find fdtget sha256sum tar cmp awk unsquashfs mktemp; do
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
readonly BBR_PATCH="$OMR_DIR/6.18/target/linux/generic/hack-6.18/999-tcp_bbr-v3-update-TCP-bbr-congestion-control-module-.patch"
readonly DTS_SOURCE="$OMR_DIR/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts"
readonly MM_MHI_PATCH="$OMR_FEED_DIR/modemmanager/patches/010-broadband-modem-mbim-handle-mhi-pci-generic.patch"
readonly MM_QDU_PATCH="$OMR_FEED_DIR/modemmanager/patches/011-quectel-disable-at-over-mbim-on-wwan.patch"
readonly MQVPN_CONTINUITY_TEST_PATCH="$OMR_FEED_DIR/mqvpn/patches/021-path-removal-continuity-test.patch"
readonly MQVPN_RECOVERY_PATCH="$OMR_FEED_DIR/mqvpn/patches/024-preserve-live-connection-on-path-failure.patch"
readonly MQVPN_SEND_ERROR_PATCH="$OMR_FEED_DIR/mqvpn/patches/025-path-scoped-hard-send-errors.patch"
readonly MQVPN_TIMER_PATCH="$OMR_FEED_DIR/mqvpn/patches/026-demote-zero-inflight-timer-noise.patch"
readonly MQVPN_REDUNDANT_EMPTY_PATCH="$OMR_FEED_DIR/mqvpn/patches/028-skip-empty-redundant-replicas.patch"
readonly OMR_SCHEDULE_MAKEFILE="$OMR_FEED_DIR/omr-schedule/Makefile"
readonly DNS_SCHEDULER="$OMR_FEED_DIR/omr-schedule/files/usr/share/omr/schedule.d/010-services"
readonly OMR_TRACKER_MAKEFILE="$OMR_FEED_DIR/omr-tracker/Makefile"
readonly OMR_TRACKER_CONFIG="$OMR_FEED_DIR/omr-tracker/files/etc/config/omr-tracker"
readonly OWNER_GUARD="$OMR_DIR/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner"
readonly FW4_COMPAT="$OMR_DIR/common/package/base-files/files/etc/uci-defaults/99-fw4-videochat-compat"
readonly MPTCP_SYNC="$OMR_DIR/common/package/base-files/files/etc/hotplug.d/iface/31-mptcp-modemmanager-endpoint-sync"
readonly MQVPN_MAKEFILE="$OMR_FEED_DIR/mqvpn/Makefile"
readonly MQVPN_CONFIG="$OMR_FEED_DIR/mqvpn/files/etc/config/mqvpn"
readonly MQVPN_INIT="$OMR_FEED_DIR/mqvpn/files/etc/init.d/mqvpn"
readonly MQVPN_DEFAULTS="$OMR_FEED_DIR/mqvpn/files/etc/uci-defaults/4102-mqvpn"
readonly MQVPN_HELPER="$OMR_FEED_DIR/mqvpn/files/usr/bin/mqvpn-path"
readonly TRACKER_ERROR="$OMR_FEED_DIR/omr-tracker/files/usr/share/omr/post-tracking.d/002-error"
readonly TRACKER_UP="$OMR_FEED_DIR/omr-tracker/files/usr/share/omr/post-tracking.d/003-up"
readonly MQVPN_PATH_HOOK="$OMR_FEED_DIR/omr-tracker/files/usr/share/omr/post-tracking.d/005-mqvpn-path"
require_file "$KERNEL_PATCH"
require_file "$BBR_PATCH"
require_file "$DTS_SOURCE"
require_file "$MM_MHI_PATCH"
require_file "$MM_QDU_PATCH"
require_file "$MQVPN_CONTINUITY_TEST_PATCH"
require_file "$MQVPN_RECOVERY_PATCH"
require_file "$MQVPN_SEND_ERROR_PATCH"
require_file "$MQVPN_TIMER_PATCH"
require_file "$MQVPN_REDUNDANT_EMPTY_PATCH"
require_file "$OMR_SCHEDULE_MAKEFILE"
require_file "$DNS_SCHEDULER"
require_file "$OMR_TRACKER_MAKEFILE"
require_file "$OMR_TRACKER_CONFIG"
require_file "$OWNER_GUARD"
require_file "$FW4_COMPAT"
require_file "$MPTCP_SYNC"
require_file "$MQVPN_MAKEFILE"
require_file "$MQVPN_CONFIG"
require_file "$MQVPN_INIT"
require_file "$MQVPN_DEFAULTS"
require_file "$MQVPN_HELPER"
require_file "$TRACKER_ERROR"
require_file "$TRACKER_UP"
require_file "$MQVPN_PATH_HOOK"
[[ -x "$OWNER_GUARD" ]] || fail 'cellular ownership guard is not executable'
[[ -x "$FW4_COMPAT" ]] || fail 'fw4 video-chat compatibility script is not executable'
[[ -x "$MPTCP_SYNC" ]] || fail 'MPTCP endpoint synchronization hook is not executable'
sh -n "$MQVPN_INIT" "$MQVPN_DEFAULTS" "$MQVPN_HELPER" "$TRACKER_ERROR" "$TRACKER_UP" \
    "$MQVPN_PATH_HOOK" \
    || fail 'MQVPN/tracker runtime scripts fail shell syntax validation'
cmp -s "$KERNEL_PATCH" "$KIT_DIR/patches/kernel/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch" \
    || fail 'kernel patch differs from the audited build-kit copy'
cmp -s "$DTS_SOURCE" "$KIT_DIR/overlays/openmptcprouter/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts" \
    || fail 'GL-X3000 DTS differs from the audited build-kit copy'
cmp -s "$MM_MHI_PATCH" "$KIT_DIR/patches/modemmanager/010-broadband-modem-mbim-handle-mhi-pci-generic.patch" \
    || fail 'ModemManager MHI patch differs from the audited build-kit copy'
cmp -s "$MM_QDU_PATCH" "$KIT_DIR/patches/modemmanager/011-quectel-disable-at-over-mbim-on-wwan.patch" \
    || fail 'ModemManager WWAN QDU patch differs from the audited build-kit copy'
cmp -s "$MQVPN_CONTINUITY_TEST_PATCH" "$KIT_DIR/patches/mqvpn/021-path-removal-continuity-test.patch" \
    || fail 'MQVPN continuity test patch differs from the audited build-kit copy'
cmp -s "$MQVPN_RECOVERY_PATCH" "$KIT_DIR/patches/mqvpn/024-preserve-live-connection-on-path-failure.patch" \
    || fail 'MQVPN live-connection preservation patch differs from the audited build-kit copy'
cmp -s "$MQVPN_SEND_ERROR_PATCH" "$KIT_DIR/patches/mqvpn/025-path-scoped-hard-send-errors.patch" \
    || fail 'MQVPN hard-send-error patch differs from the audited build-kit copy'
cmp -s "$MQVPN_TIMER_PATCH" "$KIT_DIR/patches/mqvpn/026-demote-zero-inflight-timer-noise.patch" \
    || fail 'MQVPN zero-inflight timer patch differs from the audited build-kit copy'
cmp -s "$MQVPN_REDUNDANT_EMPTY_PATCH" "$KIT_DIR/patches/mqvpn/028-skip-empty-redundant-replicas.patch" \
    || fail 'MQVPN empty redundant-replica patch differs from the audited build-kit copy'
cmp -s "$MQVPN_MAKEFILE" "$KIT_DIR/overlays/openmptcprouter-feed/mqvpn/Makefile" \
    || fail 'MQVPN recipe differs from the audited build-kit copy'
cmp -s "$MQVPN_INIT" "$KIT_DIR/overlays/openmptcprouter-feed/mqvpn/files/etc/init.d/mqvpn" \
    || fail 'MQVPN init script differs from the audited build-kit copy'
cmp -s "$MQVPN_DEFAULTS" "$KIT_DIR/overlays/openmptcprouter-feed/mqvpn/files/etc/uci-defaults/4102-mqvpn" \
    || fail 'MQVPN defaults differ from the audited build-kit copy'
cmp -s "$MQVPN_HELPER" "$KIT_DIR/overlays/openmptcprouter-feed/mqvpn/files/usr/bin/mqvpn-path" \
    || fail 'MQVPN path helper differs from the audited build-kit copy'
cmp -s "$OWNER_GUARD" "$KIT_DIR/overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner" \
    || fail 'cellular ownership guard differs from the audited build-kit copy'
cmp -s "$FW4_COMPAT" "$KIT_DIR/overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-fw4-videochat-compat" \
    || fail 'fw4 video-chat compatibility script differs from the audited build-kit copy'
cmp -s "$MPTCP_SYNC" "$KIT_DIR/overlays/openmptcprouter/common/package/base-files/files/etc/hotplug.d/iface/31-mptcp-modemmanager-endpoint-sync" \
    || fail 'MPTCP endpoint synchronization hook differs from the audited build-kit copy'
grep -Fqx 'LINUX_VERSION-6.18 = .34' "$SOURCE_ROOT/target/linux/generic/kernel-6.18" \
    || fail 'unexpected Linux 6.18 point release'
grep -Fqx 'PKG_RELEASE:=6' "$OMR_FEED_DIR/modemmanager/Makefile" \
    || fail 'ModemManager package release was not bumped for both fixes'
grep -Fq 'mhi_quectel_rm5xx_info' "$KERNEL_PATCH" || fail 'kernel patch does not select the upstream Quectel profile'
grep -Fq 'div_u64(bytes, mss_now)' "$BBR_PATCH" || fail 'BBRv3 div_u64 compatibility fix is missing'
if grep -Fq 'div_u64(bytes / mss_now)' "$BBR_PATCH"; then
    fail 'obsolete one-argument BBRv3 div_u64 call is still present'
fi
grep -Fq 'PCI_DEVICE_SUB(PCI_VENDOR_ID_QCOM, 0x0308, PCI_VENDOR_ID_QCOM, 0x5201)' "$KERNEL_PATCH" || fail 'kernel patch has the wrong PCI subsystem match'
grep -Fq 'bootargs-append = " pcie_port_pm=off";' "$DTS_SOURCE" || fail 'DTS lacks early PCIe port-PM disable'
grep -Fq "$MODEMMANAGER_BACKPORT" "$MM_MHI_PATCH" || fail 'ModemManager backport provenance is missing'
grep -Fq 'AT over MBIM disabled on WWAN port' "$MM_QDU_PATCH" \
    || fail 'ModemManager WWAN QDU guard marker is missing'
grep -Fq '$(INSTALL_BIN) ./files/usr/bin/mqvpn-path $(1)/usr/bin/mqvpn-path' "$MQVPN_MAKEFILE" \
    || fail 'mqvpn-path is not installed as an executable'
grep -Fqx "PKG_SOURCE_VERSION:=$MQVPN_SOURCE_COMMIT" "$MQVPN_MAKEFILE" \
    || fail 'MQVPN package source revision is not the audited commit'
grep -Fqx 'PKG_VERSION:=0.14.1' "$MQVPN_MAKEFILE" \
    || fail 'MQVPN package is not the selected 0.14.1 release'
grep -Fqx 'PKG_RELEASE:=10' "$MQVPN_MAKEFILE" \
    || fail 'MQVPN package release was not bumped for timer-log and continuity defaults'
grep -Fqx 'PKG_RELEASE:=2' "$OMR_SCHEDULE_MAKEFILE" \
    || fail 'omr-schedule package release was not bumped for DNS recovery guards'
grep -Fqx 'PKG_RELEASE:=2' "$OMR_TRACKER_MAKEFILE" \
    || fail 'omr-tracker package release was not bumped for hooks and cadence'
grep -Fqx $'\toption interval '\''5'\''' "$OMR_TRACKER_CONFIG" \
    || fail 'omr-tracker clean-install cadence is still too aggressive'
grep -Fq 'DEPENDS:=+kmod-tun +libevent2 +libstdcpp' "$MQVPN_MAKEFILE" \
    || fail 'MQVPN package does not declare its libstdc++ runtime dependency'
grep -Fqx "BSSL_COMMIT:=$MQVPN_BORINGSSL_COMMIT" "$MQVPN_MAKEFILE" \
    || fail 'MQVPN BoringSSL revision is not pinned to the audited commit'
grep -Fq -- '-DCMAKE_BUILD_TYPE=Release' "$MQVPN_MAKEFILE" \
    || fail 'MQVPN BoringSSL build is not optimized'
grep -Fq "set mqvpn.control.control_port='9091'" "$MQVPN_DEFAULTS" \
    || fail 'MQVPN localhost control API is not enabled by default'
grep -Fq "uci -q set mqvpn.multipath.scheduler='redundant'" "$MQVPN_DEFAULTS" \
    || fail 'MQVPN defaults do not migrate the unsupported legacy backup scheduler'
grep -Fqx $'\toption scheduler '\''redundant'\''' "$MQVPN_CONFIG" \
    || fail 'MQVPN clean-install config does not default to redundant scheduling'
grep -Fqx $'\toption reinjection_control '\''0'\''' "$MQVPN_CONFIG" \
    || fail 'MQVPN clean-install config enables separate reinjection with redundant scheduling'
grep -Fq "config_get scheduler multipath scheduler 'redundant'" "$MQVPN_INIT" \
    || fail 'MQVPN init script does not default to redundant scheduling'
grep -Fqx $'\tumask 077' "$MQVPN_INIT" \
    || fail 'MQVPN runtime config is not created under a private umask'
grep -Fqx $'\tchmod 600 "$CONF"' "$MQVPN_INIT" \
    || fail 'MQVPN runtime config permissions are not forced to 0600'
grep -Fq 'uci -q delete mqvpn.multipath.backup_path' "$MQVPN_DEFAULTS" \
    || fail 'MQVPN defaults do not migrate the legacy backup path list'
require_tracker_restart_policy "$TRACKER_ERROR"
grep -Fq 'if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then' "$TRACKER_UP" \
    || fail 'tracker does not recover PID-less stale locks'
if grep -Fq 'Only act on status transitions to avoid spamming the API on every poll' "$MQVPN_PATH_HOOK"; then
    fail 'MQVPN path hook still skips healthy-state reconciliation'
fi
test_explicit_mqvpn_error_noop "$MQVPN_PATH_HOOK"
test_dead_mqvpn_backup_not_selected "$TRACKER_ERROR"
grep -Fq 'openmptcprouter.settings.dns_health_autorestart)" = "1"' "$DNS_SCHEDULER" \
    || fail 'OMR scheduler still allows a single DNS query to restart Unbound'
grep -Fq 'openmptcprouter.settings.dns_hijack_autoswitch)" = "1"' "$DNS_SCHEDULER" \
    || fail 'OMR scheduler still auto-switches LAN DNS on one direct-WAN probe'
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
require_string "${mm_binaries[0]}" 'AT over MBIM disabled on WWAN port'

mapfile -t mm_packages < <(find "$SOURCE_ROOT/bin/packages" -type f \
    -name "modemmanager-${MODEMMANAGER_VERSION}-r6.apk" -print | sort)
[[ "${#mm_packages[@]}" -gt 0 ]] || fail 'ModemManager r6 APK not found'

mapfile -t mqvpn_build_dirs < <(find "$SOURCE_ROOT/build_dir" -type d \
    -name 'mqvpn-0.14.1' -exec test -f '{}/src/mqvpn_client.c' \; -print | sort)
if [[ "${#mqvpn_build_dirs[@]}" -gt 0 ]]; then
    readonly mqvpn_build_dir="${mqvpn_build_dirs[0]}"
    grep -Fq 'preserving validated sibling path[%d] %s' "$mqvpn_build_dir/src/mqvpn_client.c" \
        || fail 'MQVPN source can still reconnect for a failed secondary path budget'
    grep -Fq 'refusing removal of final validated path' "$mqvpn_build_dir/src/mqvpn_client.c" \
        || fail 'MQVPN source does not protect the final live path'
    grep -Fq 'mqvpn_path_budget_should_reconnect' "$mqvpn_build_dir/src/path_error_policy.h" \
        || fail 'MQVPN source lacks the live-sibling reconnect policy'
    grep -Fq 'hard socket send error on path %s' "$mqvpn_build_dir/src/mqvpn_client.c" \
        || fail 'MQVPN source lacks path-scoped hard socket error handling'
    if grep -Fq 'path_send_dead_retcode' "$mqvpn_build_dir/src/mqvpn_client.c"; then
        fail 'MQVPN source still disguises hard socket failures as EAGAIN'
    fi
    grep -Fq 'ASSERT_TRUE(failures == 5);' "$mqvpn_build_dir/tests/test_path_error_policy.c" \
        || fail 'MQVPN path-policy test still calls an undefined assertion helper'
    grep -Fq 'xqc_log(conn->log, XQC_LOG_DEBUG, "|peer validated address while inflight bytes is 0|");' \
        "$mqvpn_build_dir/third_party/xquic/src/transport/xqc_timer.c" \
        || fail 'xquic zero-inflight timer diagnostic is not demoted to debug'
    if grep -Fq 'XQC_LOG_WARN, "|exception|peer validated address while inflight bytes is 0|"' \
        "$mqvpn_build_dir/third_party/xquic/src/transport/xqc_timer.c"; then
        fail 'xquic still floods warnings for acknowledged zero-inflight timers'
    fi
    readonly mqvpn_bssl_dir="$mqvpn_build_dir/third_party/xquic/third_party/boringssl"
    if [[ -d "$mqvpn_bssl_dir/.git" ]]; then
        check_revision "$mqvpn_bssl_dir" "$MQVPN_BORINGSSL_COMMIT" BoringSSL
    fi
    if [[ -f "$mqvpn_bssl_dir/build/CMakeCache.txt" ]]; then
        grep -Fqx 'CMAKE_BUILD_TYPE:STRING=Release' "$mqvpn_bssl_dir/build/CMakeCache.txt" \
            || fail 'compiled BoringSSL cache is not a Release build'
    fi
fi

mapfile -t mqvpn_binaries < <(find "$SOURCE_ROOT/build_dir" -type f \
    -path '*/root-mediatek/usr/sbin/mqvpn' -print | sort)
[[ "${#mqvpn_binaries[@]}" -gt 0 ]] || fail 'installed MQVPN binary not found'
require_substring "${mqvpn_binaries[0]}" 'mqvpn %s'
require_substring "${mqvpn_binaries[0]}" 'preserving validated sibling'
require_substring "${mqvpn_binaries[0]}" 'refusing removal of final validated path'
require_substring "${mqvpn_binaries[0]}" 'hard socket send error on path'

mapfile -t mqvpn_packages < <(find "$SOURCE_ROOT/bin/packages" -type f \
    -name 'mqvpn-0.14.1-r10.apk' -print | sort)
[[ "${#mqvpn_packages[@]}" -gt 0 ]] || fail 'MQVPN 0.14.1-r10 APK not found'

mapfile -t omr_schedule_packages < <(find "$SOURCE_ROOT/bin/packages" -type f \
    -name 'omr-schedule-0.1-r2.apk' -print | sort)
[[ "${#omr_schedule_packages[@]}" -gt 0 ]] || fail 'omr-schedule 0.1-r2 APK not found'

mapfile -t omr_tracker_packages < <(find "$SOURCE_ROOT/bin/packages" -type f \
    -name 'omr-tracker-*-r2.apk' -print | sort)
[[ "${#omr_tracker_packages[@]}" -gt 0 ]] || fail 'omr-tracker r2 APK not found'

readonly TARGET_BIN_DIR="$SOURCE_ROOT/bin/targets/mediatek/filogic"
mapfile -t images < <(find "$TARGET_BIN_DIR" -maxdepth 1 -type f \
    -name '*glinet_gl-x3000*squashfs-sysupgrade.bin' -print | sort)
[[ "${#images[@]}" -eq 1 ]] || fail "expected one GL-X3000 sysupgrade image, found ${#images[@]}"
grep -Fqx sysupgrade-glinet_gl-x3000/CONTROL < <(tar -tf "${images[0]}") \
    || fail 'sysupgrade archive lacks the GL-X3000 control entry'

readonly root_audit="$(mktemp -d /tmp/gl-x3000-root.XXXXXX)"
tar -xOf "${images[0]}" sysupgrade-glinet_gl-x3000/root > "$root_audit/root.squashfs"
# Device nodes cannot be recreated by the intentionally unprivileged build
# user. Preserve all ordinary file metadata but do not fail extraction solely
# for those expected mknod errors.
unsquashfs -no-exit-code -d "$root_audit/rootfs" \
    "$root_audit/root.squashfs" >/dev/null 2>&1
readonly distfeeds="$root_audit/rootfs/etc/apk/repositories.d/distfeeds.list"
readonly customfeeds="$root_audit/rootfs/etc/apk/repositories.d/customfeeds.list"
readonly installed_guard="$root_audit/rootfs/etc/uci-defaults/99-cellular-control-owner"
readonly installed_fw4_compat="$root_audit/rootfs/etc/uci-defaults/99-fw4-videochat-compat"
readonly installed_mptcp_sync="$root_audit/rootfs/etc/hotplug.d/iface/31-mptcp-modemmanager-endpoint-sync"
readonly installed_mqvpn_defaults="$root_audit/rootfs/etc/uci-defaults/4102-mqvpn"
readonly installed_mqvpn_config="$root_audit/rootfs/etc/config/mqvpn"
readonly installed_mqvpn_init="$root_audit/rootfs/etc/init.d/mqvpn"
readonly installed_mqvpn_helper="$root_audit/rootfs/usr/bin/mqvpn-path"
readonly installed_mqvpn="$root_audit/rootfs/usr/sbin/mqvpn"
readonly installed_tracker_error="$root_audit/rootfs/usr/share/omr/post-tracking.d/002-error"
readonly installed_tracker_up="$root_audit/rootfs/usr/share/omr/post-tracking.d/003-up"
readonly installed_tracker_config="$root_audit/rootfs/etc/config/omr-tracker"
readonly installed_mqvpn_path_hook="$root_audit/rootfs/usr/share/omr/post-tracking.d/005-mqvpn-path"
readonly installed_dns_scheduler="$root_audit/rootfs/usr/share/omr/schedule.d/010-services"
require_file "$distfeeds"
require_file "$customfeeds"
require_file "$installed_guard"
require_file "$installed_fw4_compat"
require_file "$installed_mptcp_sync"
require_file "$installed_mqvpn_defaults"
require_file "$installed_mqvpn_config"
require_file "$installed_mqvpn_init"
require_file "$installed_mqvpn_helper"
require_file "$installed_mqvpn"
require_file "$installed_tracker_error"
require_file "$installed_tracker_up"
require_file "$installed_tracker_config"
require_file "$installed_mqvpn_path_hook"
require_file "$installed_dns_scheduler"
[[ -x "$installed_fw4_compat" ]] || fail 'installed fw4 video-chat compatibility script is not executable'
[[ -x "$installed_mptcp_sync" ]] || fail 'installed MPTCP endpoint synchronization hook is not executable'
[[ -x "$installed_mqvpn_helper" ]] || fail 'installed mqvpn-path helper is not executable'
require_substring "$installed_mqvpn" 'mqvpn %s'
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
grep -Fq "match='dest_net dest_port'" "$installed_fw4_compat" \
    || fail 'installed fw4 compatibility script lacks address-and-port tuple matching'
grep -Fq 'omr_dst_videochatv4_port' "$installed_fw4_compat" \
    || fail 'installed fw4 compatibility script lacks the IPv4 tuple-set migration'
grep -Fq 'omr_dst_videochatv6_port' "$installed_fw4_compat" \
    || fail 'installed fw4 compatibility script lacks the IPv6 tuple-set migration'
grep -Fq 'config_interface="${INTERFACE%_4}"' "$installed_mptcp_sync" \
    || fail 'installed MPTCP hook does not normalize dynamic IPv4 interface names'
grep -Fq 'mptcp-endpoint-sync' "$installed_mptcp_sync" \
    || fail 'installed MPTCP hook lacks its audit log marker'
grep -Fq "set mqvpn.control.control_port='9091'" "$installed_mqvpn_defaults" \
    || fail 'installed MQVPN defaults lack the control API port'
grep -Fqx $'\tumask 077' "$installed_mqvpn_init" \
    || fail 'installed MQVPN init lacks the private runtime-config umask'
grep -Fqx $'\tchmod 600 "$CONF"' "$installed_mqvpn_init" \
    || fail 'installed MQVPN init does not enforce runtime-config mode 0600'
grep -Fq "uci -q set mqvpn.multipath.scheduler='redundant'" "$installed_mqvpn_defaults" \
    || fail 'installed MQVPN defaults lack the legacy scheduler migration'
grep -Fqx $'\toption scheduler '\''redundant'\''' "$installed_mqvpn_config" \
    || fail 'installed MQVPN config does not default to redundant scheduling'
grep -Fq 'uci -q delete mqvpn.multipath.backup_path' "$installed_mqvpn_defaults" \
    || fail 'installed MQVPN defaults lack the legacy path migration'
require_tracker_restart_policy "$installed_tracker_error"
grep -Fq 'if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then' "$installed_tracker_up" \
    || fail 'installed tracker does not recover PID-less stale locks'
grep -Fqx $'\toption interval '\''5'\''' "$installed_tracker_config" \
    || fail 'installed tracker config does not use the relaxed cadence'
if grep -Fq 'Only act on status transitions to avoid spamming the API on every poll' "$installed_mqvpn_path_hook"; then
    fail 'installed MQVPN path hook still skips healthy-state reconciliation'
fi
test_explicit_mqvpn_error_noop "$installed_mqvpn_path_hook"
test_dead_mqvpn_backup_not_selected "$installed_tracker_error"
grep -Fq 'openmptcprouter.settings.dns_health_autorestart)" = "1"' "$installed_dns_scheduler" \
    || fail 'installed scheduler can restart Unbound on one query failure'
grep -Fq 'openmptcprouter.settings.dns_hijack_autoswitch)" = "1"' "$installed_dns_scheduler" \
    || fail 'installed scheduler can auto-switch LAN DNS on one WAN probe'

printf 'OMR=%s\n' "$OMR_COMMIT"
printf 'OMR_FEED=%s\n' "$OMR_FEED_COMMIT"
printf 'OPENWRT=%s\n' "$OPENWRT_COMMIT"
printf 'KERNEL=%s\n' "$LINUX_VERSION"
printf 'MODEMMANAGER=%s+%s+%s\n' \
    "$MODEMMANAGER_VERSION" "$MODEMMANAGER_BACKPORT" "$MODEMMANAGER_QDU_GUARD"
printf 'MQVPN=%s\n' "$MQVPN_SOURCE_COMMIT"
printf 'XQUIC=%s\n' "$MQVPN_XQUIC_COMMIT"
printf 'BORINGSSL=%s\n' "$MQVPN_BORINGSSL_COMMIT"
printf 'IMAGE_SHA256='
sha256sum "${images[0]}" | awk '{print $1}'
printf 'VALIDATION=passed\n'
