#!/usr/bin/env bash
set -Eeuo pipefail

readonly KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest.lock
source "$KIT_DIR/manifest.lock"

readonly WORK_DIR="${WORK_DIR:-/work}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-/out}"
readonly OMR_DIR="$WORK_DIR/openmptcprouter"
readonly OMR_FEED_DIR="$WORK_DIR/openmptcprouter-feed"
readonly JOBS="${JOBS:-8}"
readonly PUBLIC_TARGET_REPO="${PUBLIC_TARGET_REPO:-https://download.openmptcprouter.com/release/${OMR_RELEASE}-${OMR_KERNEL}/${OMR_TARGET}}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    }
}

clone_at_commit() {
    local repository="$1"
    local commit="$2"
    local destination="$3"

    if [[ -z "$WORK_DIR" || "$WORK_DIR" == / || "$destination" != "$WORK_DIR/"* ]]; then
        printf 'Refusing unsafe source destination: %s\n' "$destination" >&2
        exit 1
    fi
    if [[ -L "$destination" ]]; then
        printf 'Refusing symlinked source destination: %s\n' "$destination" >&2
        exit 1
    fi

    if [[ ! -d "$destination/.git" ]]; then
        git clone --filter=blob:none --no-checkout "$repository" "$destination"
        git -C "$destination" fetch --depth=1 origin "$commit"
        git -C "$destination" checkout --detach "$commit"
    else
        local actual_root
        actual_root="$(git -C "$destination" rev-parse --show-toplevel)"
        if [[ "$actual_root" != "$destination" ]]; then
            printf 'Refusing unexpected Git worktree root: %s\n' "$actual_root" >&2
            exit 1
        fi

        # These trees live only under the disposable build volume. Resetting
        # them before every preparation prevents stale experimental patches or
        # untracked build inputs from leaking into a later image.
        git -C "$destination" reset --hard "$commit"
        git -C "$destination" clean -ffdx
    fi

    local actual
    actual="$(git -C "$destination" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        printf 'Refusing to reuse %s at unexpected commit %s (wanted %s)\n' \
            "$destination" "$actual" "$commit" >&2
        exit 1
    fi
}

apply_patch_exact() {
    local tree="$1"
    local patch_file="$2"

    if ! git -C "$tree" apply --check "$patch_file"; then
        printf 'Patch does not apply cleanly: %s\n' "$patch_file" >&2
        exit 1
    fi
    git -C "$tree" apply "$patch_file"
}

install_file() {
    local source_file="$1"
    local destination_file="$2"

    mkdir -p "$(dirname -- "$destination_file")"
    cp -f -- "$source_file" "$destination_file"
    chmod 0644 "$destination_file"
}

for command_name in git patch cp chmod mkdir sha256sum; do
    require_command "$command_name"
done

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
clone_at_commit "$OMR_REPOSITORY" "$OMR_COMMIT" "$OMR_DIR"
clone_at_commit "$OMR_FEED_REPOSITORY" "$OMR_FEED_COMMIT" "$OMR_FEED_DIR"

apply_patch_exact \
    "$OMR_DIR" \
    "$KIT_DIR/patches/openmptcprouter/0001-build-recognize-gl-x3000-aarch64.patch"
apply_patch_exact \
    "$OMR_DIR" \
    "$KIT_DIR/patches/openmptcprouter/0002-build-use-versioned-https-apk-feeds.patch"
apply_patch_exact \
    "$OMR_FEED_DIR" \
    "$KIT_DIR/patches/openmptcprouter-feed/0001-modemmanager-bump-release.patch"

install_file \
    "$KIT_DIR/config/config-gl-x3000" \
    "$OMR_DIR/config-gl-x3000"
install_file \
    "$KIT_DIR/patches/kernel/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch" \
    "$OMR_DIR/6.18/target/linux/generic/pending-6.18/499-bus-mhi-host-pci-generic-gl-x3000-rm520n-mbim.patch"
install_file \
    "$KIT_DIR/overlays/openmptcprouter/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts" \
    "$OMR_DIR/6.18/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000.dts"
install_file \
    "$KIT_DIR/patches/modemmanager/010-broadband-modem-mbim-handle-mhi-pci-generic.patch" \
    "$OMR_FEED_DIR/modemmanager/patches/010-broadband-modem-mbim-handle-mhi-pci-generic.patch"
install_file \
    "$KIT_DIR/patches/modemmanager/011-quectel-disable-at-over-mbim-on-wwan.patch" \
    "$OMR_FEED_DIR/modemmanager/patches/011-quectel-disable-at-over-mbim-on-wwan.patch"
install_file \
    "$KIT_DIR/overlays/openmptcprouter/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner" \
    "$OMR_DIR/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner"
chmod 0755 "$OMR_DIR/common/package/base-files/files/etc/uci-defaults/99-cellular-control-owner"

if [[ "${PREPARE_ONLY:-0}" == 1 ]]; then
    printf 'Sources and audited overlays prepared under %s\n' "$WORK_DIR"
    exit 0
fi

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$OMR_DIR" show -s --format=%ct "$OMR_COMMIT")}"

cd "$OMR_DIR"
OMR_TARGET="$OMR_TARGET" \
OMR_KERNEL="$OMR_KERNEL" \
OMR_RELEASE="$OMR_RELEASE" \
OMR_FEED="$OMR_FEED_DIR" \
OMR_FEED_SRC=develop \
OMR_HOST=download.openmptcprouter.com \
OMR_PORT=443 \
OMR_REPO="$PUBLIC_TARGET_REPO" \
OMR_KEEPBIN=no \
OMR_LOG=yes \
./build.sh -j"$JOBS"

"$KIT_DIR/validate.sh" "$OMR_DIR" "$OMR_FEED_DIR" | tee "$OUTPUT_DIR/validation.txt"

readonly TARGET_BIN_DIR="$OMR_DIR/gl-x3000/6.18/source/bin/targets/mediatek/filogic"
mapfile -t images < <(find "$TARGET_BIN_DIR" -maxdepth 1 -type f \
    -name '*glinet_gl-x3000*squashfs-sysupgrade.bin' -print | sort)
if [[ "${#images[@]}" -ne 1 ]]; then
    printf 'Expected one GL-X3000 sysupgrade image, found %s\n' "${#images[@]}" >&2
    exit 1
fi

readonly image="${images[0]}"
readonly output_image="$OUTPUT_DIR/$(basename -- "$image")"
cp -f -- "$image" "$output_image"
sha256sum "$output_image" > "$output_image.sha256"

{
    printf 'OMR_COMMIT=%s\n' "$OMR_COMMIT"
    printf 'OMR_FEED_COMMIT=%s\n' "$OMR_FEED_COMMIT"
    printf 'OPENWRT_COMMIT=%s\n' "$OPENWRT_COMMIT"
    printf 'LINUX_VERSION=%s\n' "$LINUX_VERSION"
    printf 'MODEMMANAGER_VERSION=%s\n' "$MODEMMANAGER_VERSION"
    printf 'MODEMMANAGER_BACKPORT=%s\n' "$MODEMMANAGER_BACKPORT"
    printf 'MODEMMANAGER_QDU_GUARD=%s\n' "$MODEMMANAGER_QDU_GUARD"
    printf 'SOURCE_DATE_EPOCH=%s\n' "$SOURCE_DATE_EPOCH"
    printf 'IMAGE=%s\n' "$(basename -- "$output_image")"
    sha256sum "$output_image"
} > "$OUTPUT_DIR/build-manifest.txt"

printf 'Build complete: %s\n' "$output_image"
