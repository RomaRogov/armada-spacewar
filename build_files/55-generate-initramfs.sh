#!/bin/bash
set -euxo pipefail

# Runs after 40-vendor-system-files: the initramfs bundles the armada splash,
# which is not yet installed when the kernel step runs.
KVER="$(ls /usr/lib/modules)"
IMG="/usr/lib/modules/${KVER}/initramfs.img"

# fedora-bootc ships /root -> var/roothome, absent in the build container;
# dracut-install aborts resolving /root without the target.
mkdir -p /var/roothome

dracut \
    --force \
    --no-hostonly \
    --reproducible \
    --kver "${KVER}" \
    --add ostree \
    --add armada-splash \
    --add armada-ostree-fallback \
    --add armada-userdata-subparts \
    "${IMG}" "${KVER}"

# dracut drops modules silently: fail the build rather than ship without.
# Exact match: a substring test lets armada-splash-launcher pass for the binary.
required=(
    usr/lib/systemd/system/armada-splash-initrd.service \
    usr/lib/systemd/system/dracut-pre-mount.service.d/armada-splash.conf \
    usr/libexec/armada/armada-splash \
    usr/libexec/armada/armada-splash-launcher \
    usr/libexec/armada/device-env \
    usr/share/armada/splash/splash.asp \
    usr/libexec/armada/armada-ostree-fallback \
    usr/lib/systemd/system/ostree-prepare-root.service.d/armada-fallback.conf \
    usr/lib/ostree/ostree-prepare-root
    usr/libexec/armada/armada-userdata-subparts
    usr/lib/systemd/system/armada-userdata-subparts.service
)

if ! lsinitrd "${IMG}" | awk '
    BEGIN {
        count = ARGC - 1
        for (i = 1; i <= count; i++) {
            paths[i] = ARGV[i]
            required[ARGV[i]] = 1
        }
        ARGC = 1
    }
    $NF in required { found[$NF] = 1 }
    END {
        for (i = 1; i <= count; i++) {
            if (!(paths[i] in found)) {
                print "ERROR: " paths[i] " missing from initramfs" > "/dev/stderr"
                missing = 1
            }
        }
        exit missing
    }
' "${required[@]}"; then
    dracut --list-modules --kver "${KVER}" | grep -i armada || true
    exit 1
fi

echo "initramfs generated for ${KVER} with armada-splash"

# Stock-ABL phones (ARMADA_BOOT_METHOD=android-v3) cannot boot the generic
# image: the ABL hands the kernel a truncated ramdisk once it gets this large
# (52 MB never reaches init; 16 MB does). Build a slim one next to it with only
# what mounting the root needs plus the devices' early drivers; everything
# else loads from the real root. armada_build_android_v3 callers prefer it.
V3_IMG="/usr/lib/modules/${KVER}/initramfs-android-v3.img"
v3_drivers="btrfs loop"
v3_devices=0
for conf in /usr/lib/armada/devices/*.conf; do
    grep -q '^ARMADA_BOOT_METHOD=android-v3$' "${conf}" || continue
    v3_devices=$((v3_devices + 1))
    # shellcheck source=/dev/null
    v3_drivers+=" $(ARMADA_BOOT_INITRD_DRIVERS='' && . "${conf}" && printf '%s' "${ARMADA_BOOT_INITRD_DRIVERS:-}")"
done

if (( v3_devices > 0 )); then
    v3_omit=(
        network-manager network net-lib nfs cifs iscsi nbd fcoe lunmask
        clevis clevis-pin-null clevis-pin-sss clevis-pin-tang clevis-pin-tpm2
        crypt systemd-cryptsetup tpm2-tss fido2 pkcs11 fips fips-crypto-policies
        nss-softokn openssl modsign systemd-pcrphase
        lvm mdraid dmraid multipath nvdimm resume
        qemu qemu-net virtiofs walinuxagent memstrack i18n
        kernel-modules kernel-modules-extra kernel-network-modules
    )
    # xz with crc32: the in-kernel decompressor rejects xz's default crc64.
    dracut \
        --force \
        --no-hostonly \
        --reproducible \
        --no-early-microcode \
        --kver "${KVER}" \
        --add "ostree armada-splash armada-ostree-fallback armada-userdata-subparts" \
        --omit "${v3_omit[*]}" \
        --add-drivers "${v3_drivers}" \
        --compress "xz -9e --check=crc32 -T1" \
        "${V3_IMG}" "${KVER}"

    v3_required=(
        usr/libexec/armada/armada-userdata-subparts
        usr/lib/systemd/system/armada-userdata-subparts.service
        usr/libexec/armada/armada-ostree-aboot-root
        usr/lib/systemd/system/armada-ostree-aboot-root.service
        usr/lib/ostree/ostree-prepare-root
        usr/libexec/armada/armada-splash
    )
    v3_list=$(lsinitrd "${V3_IMG}")
    for f in "${v3_required[@]}"; do
        awk -v p="${f}" '$NF == p { found = 1 } END { exit !found }' <<<"${v3_list}" \
            || { echo "ERROR: ${f} missing from ${V3_IMG}" >&2; exit 1; }
    done
    for d in ${v3_drivers}; do
        grep -Eq "/${d//-/[-_]}\.ko(\.[a-z]+)?$" <<<"${v3_list}" \
            || grep -Eq "/${d//-/[-_]}\.ko" "/usr/lib/modules/${KVER}/modules.builtin" \
            || { echo "ERROR: driver ${d} neither in ${V3_IMG} nor built in" >&2; exit 1; }
    done
    # Keep well under the size the ABL handed over intact in testing.
    v3_size=$(stat -c %s "${V3_IMG}")
    (( v3_size <= 24 * 1024 * 1024 )) \
        || { echo "ERROR: ${V3_IMG} is ${v3_size} bytes; the stock ABL needs it small" >&2; exit 1; }
    echo "android-v3 initramfs: ${V3_IMG} (${v3_size} bytes, drivers: ${v3_drivers})"
fi
