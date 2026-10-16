#!/bin/bash
set -euxo pipefail

# Nothing Phone (1) (spacewar) DSP, modem, Wi-Fi, GPU-zap and touch firmware,
# from the mainlining project's extraction (the same set postmarketOS ships).
# Fetched at a pinned commit and checksum instead of vendored: the archive is
# 100 MB, most of it carrier modem configs a gaming OS doesn't need.
commit=cc01a8900344afb8a8e254f7bb607d1b4affeb3c
sha256=3cc55c66647ffce3fcd532029f1b684b23cb90f2d243f88941576496c1a1a003
url="https://github.com/mainlining/firmware-nothing-spacewar/archive/${commit}.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
curl -fsSL --retry 5 -o "${work}/fw.tar.gz" "${url}"
echo "${sha256}  ${work}/fw.tar.gz" | sha256sum -c -
tar -xzf "${work}/fw.tar.gz" -C "${work}"
src="${work}/firmware-nothing-spacewar-${commit}/lib/firmware"

dst=/usr/lib/firmware/qcom/sm7325/nothing/spacewar
install -d "${dst}"
for f in a660_zap.mbn adsp.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn \
    cdsp.mbn cdspr.jsn focaltech_ts_novatek.bin ipa_fws.mbn modem.mbn \
    modemr.jsn vpu20_1v.mbn wpss.mbn; do
    install -m 0644 "${src}/qcom/sm7325/nothing/spacewar/${f}" "${dst}/${f}"
done

# Board data with the spacewar calibration variant; WCN6750 is spacewar-only
# among Armada devices, and updates/ takes precedence over atheros-firmware.
install -D -m 0644 "${src}/postmarketos/ath11k/WCN6750/hw1.0/board-2.bin" \
    /usr/lib/firmware/updates/ath11k/WCN6750/hw1.0/board-2.bin

# Sensor DSP side of the Snapdragon Sensor Core (armada-ssc-imu): the hexagon
# libraries the sensor PD loads over FastRPC and the socinfo it probes. Its
# configs and calibrated registry come from the phone's own partitions at boot.
share="${work}/firmware-nothing-spacewar-${commit}/usr/share/qcom/sm7325/Nothing/spacewar"
install -d /usr/share/qcom/sm7325/nothing/spacewar
cp -a "${share}/dsp" "${share}/socinfo" /usr/share/qcom/sm7325/nothing/spacewar/
