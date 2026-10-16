#!/bin/bash
# Turn the BIB disk.raw into fastboot images for a stock-ABL phone
# (ARMADA_BOOT_METHOD=android-v3): boot/vendor_boot for the active slot, a
# no-op dtbo, and the whole GPT disk image as a sparse userdata image.
set -euo pipefail

RAW="${1:-output/image/disk.raw}"
DEVICE="${2:-nothing-phone-1}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${SCRIPT_DIR}/.."
ARMADA_LIB="${REPO_ROOT}/system_files/usr/lib/armada"
DEVICE_CONF="${ARMADA_LIB}/devices/${DEVICE}.conf"
DTBO_SPEC="${SCRIPT_DIR}/android-v3/${DEVICE}.dtbo.json"
OUT="${OUT:-output/${DEVICE}}"
export MKBOOTIMG="${REPO_ROOT}/build_files/vendor/mkbootimg/mkbootimg.py"
export AVBTOOL="${REPO_ROOT}/build_files/vendor/avbtool/avbtool.py"
# Partition sizes on the device (fastboot getvar partition-size:<name>).
BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-100663296}"
DTBO_PARTITION_SIZE="${DTBO_PARTITION_SIZE:-25165824}"

[[ -f "${RAW}" ]] || { echo "raw image not found: ${RAW} (run 'just build-raw' first)"; exit 1; }
[[ -r "${DEVICE_CONF}" ]] || { echo "unknown device: ${DEVICE}"; exit 1; }
[[ -r "${DTBO_SPEC}" ]] || { echo "missing dtbo spec: ${DTBO_SPEC}"; exit 1; }
for tool in dtc cpio img2simg python3; do
    command -v "${tool}" >/dev/null || { echo "missing host tool: ${tool}"; exit 1; }
done

# shellcheck source=/dev/null
source "${DEVICE_CONF}"
[[ "${ARMADA_BOOT_METHOD:-}" == android-v3 ]] || { echo "${DEVICE} is not an android-v3 device"; exit 1; }
source "${ARMADA_LIB}/bootimg-args"
source "${ARMADA_LIB}/bootimg-android-v3"

WORK=$(mktemp -d)
LOOP=$(sudo losetup -fP --show "${RAW}")
trap 'sudo umount "${WORK}/root" 2>/dev/null || true; sudo umount "${WORK}/boot" 2>/dev/null || true; sudo losetup -d "${LOOP}" 2>/dev/null || true; sudo rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/boot" "${OUT}"
# BIB lays out ESP, /boot, root; `bootc install to-disk` lays out ESP and a root
# that carries /boot. Find the BLS entries either way.
sudo mount -o ro "${LOOP}p2" "${WORK}/boot"
BOOTDIR="${WORK}/boot"
if ! sudo test -d "${BOOTDIR}/loader/entries" && sudo test -d "${BOOTDIR}/boot/loader/entries"; then
    BOOTDIR="${WORK}/boot/boot"
fi

ENTRY=$(sudo bash -c "source '${ARMADA_LIB}/bootimg-args'; armada_default_bls_entry '${BOOTDIR}'")
[[ -n "${ENTRY}" ]] || { echo "no BLS entry in ${RAW}"; exit 1; }
LINUX_LINE=$(sudo sed -n 's/^linux //p' "${ENTRY}" | head -1)
INITRD_LINE=$(sudo sed -n 's/^initrd //p' "${ENTRY}" | head -1)
OPTIONS_LINE=$(sudo sed -n 's/^options //p' "${ENTRY}" | head -1)
KPATH="${BOOTDIR}${LINUX_LINE#/boot}"
IPATH="${BOOTDIR}${INITRD_LINE#/boot}"
DTB="$(dirname "${KPATH}")/dtb/qcom/${ARMADA_BOOT_DTB}.dtb"
sudo test -f "${DTB}" || { echo "deployment has no ${ARMADA_BOOT_DTB}.dtb (kernel package too old?)"; exit 1; }

# The slim initramfs lives in the deployment; with the BIB layout the root is
# its own partition.
ROOTDIR="${WORK}/boot"
if [[ "${BOOTDIR}" == "${WORK}/boot" ]]; then
    mkdir -p "${WORK}/root"
    sudo mount -o ro "${LOOP}p3" "${WORK}/root"
    ROOTDIR="${WORK}/root"
fi
OSTREE_KARG=$(tr ' ' '\n' <<<"${OPTIONS_LINE}" | sed -n 's/^ostree=//p' | head -1)
DEPLOY=$(sudo readlink -f "${ROOTDIR}${OSTREE_KARG}")
IPATH=$(sudo bash -c "source '${ARMADA_LIB}/bootimg-android-v3'; armada_v3_initramfs '${DEPLOY}' '${LINUX_LINE##*/vmlinuz-}' '${IPATH}'")

# Copy out what we need so the build runs unprivileged on plain files.
sudo cat "${KPATH}" > "${WORK}/Image"
sudo cat "${IPATH}" > "${WORK}/initramfs"
sudo cat "${DTB}" > "${WORK}/board.dtb"

CMDLINE=$(armada_v3_cmdline "${OPTIONS_LINE}" "${ARMADA_BOOT_EXTRA_CMDLINE:-}") \
    || { echo "ERROR: no ostree= karg in ${ENTRY}"; exit 1; }
armada_build_android_v3 "${WORK}/Image" "${WORK}/initramfs" "${WORK}/board.dtb" \
    "${CMDLINE}" "${OUT}" "${BOOT_PARTITION_SIZE}"

python3 "${SCRIPT_DIR}/android-v3/mkdtbo-noop.py" "${DTBO_SPEC}" "${OUT}/dtbo.img"
python3 "${AVBTOOL}" add_hash_footer --image "${OUT}/dtbo.img" \
    --partition_name dtbo --partition_size "${DTBO_PARTITION_SIZE}" --algorithm NONE

# The Armada GPT (ESP, /boot, root) goes inside userdata as a whole; the
# initrd maps it with a partscanning loop device (armada.userdata_subparts).
img2simg "${RAW}" "${OUT}/userdata.img"

cat > "${OUT}/flash.sh" <<'FLASH'
#!/bin/sh
# Flash Armada to a stock-ABL phone in fastboot mode. ERASES Android userdata.
# Writes the active slot's boot/vendor_boot/dtbo; back up first.
set -e
cd "$(dirname "$0")"
slot=$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: *//p')
[ -n "$slot" ] || { echo "no fastboot device / slot"; exit 1; }
fastboot flash "boot_$slot" boot.img
fastboot flash "vendor_boot_$slot" vendor_boot.img
fastboot flash "dtbo_$slot" dtbo.img
fastboot flash userdata userdata.img
fastboot reboot
FLASH
chmod +x "${OUT}/flash.sh"

echo "cmdline=${CMDLINE}"
echo "initramfs=${IPATH#"${WORK}"} ($(stat -c %s "${WORK}/initramfs") bytes)"
ls -l "${OUT}"
