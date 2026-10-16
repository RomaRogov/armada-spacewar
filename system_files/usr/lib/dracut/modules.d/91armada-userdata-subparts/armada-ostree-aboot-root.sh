#!/bin/bash
# The stock ABL always appends androidboot.slot_suffix, which switches
# ostree-prepare-root into its Android-boot mode: it ignores ostree= and boots
# /ostree/root.<slot> instead. Point that symlink at the deployment the boot
# image's ostree= karg names, so it follows every regenerated boot image.
set -u

ostree= slot=
for arg in $(< /proc/cmdline); do
    case "${arg}" in
        ostree=*) ostree=${arg#ostree=} ;;
        androidboot.slot_suffix=_?) slot=${arg#androidboot.slot_suffix=_} ;;
    esac
done
[ -n "${ostree}" ] || exit 0
# Like ostree, fall back to bootconfig, where some ABLs pass the slot instead.
if [ -z "${slot}" ] && [ -r /proc/bootconfig ]; then
    while IFS= read -r line; do
        case "${line}" in
            androidboot.slot_suffix*=*\"_?\"*)
                line=${line#*\"_}
                slot=${line%%\"*} ;;
        esac
    done < /proc/bootconfig
fi

deploy=$(readlink -f "/sysroot${ostree}") || exit 1
[ -d "${deploy}" ] || { echo "armada-ostree-aboot-root: ${ostree} does not resolve" >&2; exit 1; }
case "${deploy}" in
    /sysroot/ostree/*) rel=${deploy#/sysroot/ostree/} ;;
    *) echo "armada-ostree-aboot-root: ${deploy} is outside /sysroot/ostree" >&2; exit 1 ;;
esac

# Unknown slot: point both, ostree picks whichever the ABL reports.
for s in ${slot:-a b}; do
    link=/sysroot/ostree/root.${s}
    [ "$(readlink "${link}" 2>/dev/null)" = "${rel}" ] && continue
    ln -sfn "${rel}" "${link}"
    echo "armada-ostree-aboot-root: root.${s} -> ${rel}"
done
