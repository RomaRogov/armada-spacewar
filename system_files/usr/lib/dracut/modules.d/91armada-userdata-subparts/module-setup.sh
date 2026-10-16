#!/bin/bash
# Maps the Armada GPT flashed inside Android's userdata partition on stock-ABL
# phones; see armada-userdata-subparts.sh.

check() {
    # 255 = explicit --add only, matching the other armada modules.
    return 255
}

depends() {
    echo systemd
    return 0
}

installkernel() {
    hostonly='' instmods loop
}

install() {
    inst_multiple losetup udevadm blkid sleep readlink grep ln
    inst_script "$moddir/armada-userdata-subparts.sh" \
        /usr/libexec/armada/armada-userdata-subparts
    inst_simple "$moddir/armada-userdata-subparts.service" \
        "$systemdsystemunitdir/armada-userdata-subparts.service"
    inst_script "$moddir/armada-ostree-aboot-root.sh" \
        /usr/libexec/armada/armada-ostree-aboot-root
    inst_simple "$moddir/armada-ostree-aboot-root.service" \
        "$systemdsystemunitdir/armada-ostree-aboot-root.service"
    $SYSTEMCTL -q --root "$initdir" enable armada-userdata-subparts.service
    $SYSTEMCTL -q --root "$initdir" enable armada-ostree-aboot-root.service
}
