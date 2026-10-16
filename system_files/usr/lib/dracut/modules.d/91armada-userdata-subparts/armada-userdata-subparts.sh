#!/bin/bash
# Stock-ABL phones can't repartition the UFS from fastboot, so the Armada disk
# image (ESP, /boot, root) is flashed as a whole GPT into the userdata
# partition. The kernel doesn't scan partition tables inside a partition; a
# partscanning loop device exposes them so root=UUID=... resolves as usual.
set -u

dev=/dev/disk/by-partlabel/userdata
# Pure bash: the initramfs has no seq.
for ((i = 0; i < 600; i++)); do
    [ -b "${dev}" ] && break
    sleep 0.1
done
[ -b "${dev}" ] || { echo "armada-userdata-subparts: ${dev} never appeared" >&2; exit 1; }

target=$(readlink -f "${dev}")
if losetup -j "${target}" | grep -q .; then
    exit 0
fi
# The image's GPT uses 512-byte sectors, but UFS userdata has 4096-byte logical
# blocks and the loop driver inherits the backing device's block size by
# default, which would misread every LBA in the table.
loopdev=$(losetup --find --show --partscan --sector-size 512 "${target}") || exit 1
udevadm settle --timeout=10 || true
parts=("${loopdev}"p*)
echo "armada-userdata-subparts: ${target} -> ${loopdev} (${parts[*]})"
