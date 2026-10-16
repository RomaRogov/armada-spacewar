#!/usr/bin/env python3
"""Build a no-op dtbo partition image for a stock Qualcomm ABL.

The ABL refuses to boot without a valid DTBO table that has an entry matching
the board, and applies the chosen entry with Qualcomm's ufdt fork, which
requires a __fixups__ node in every overlay and copies an overlay's root
properties onto the base. Each entry here therefore carries the ABL match
properties, the device's real model/compatible, and an empty fragment on &soc.

Usage: mkdtbo-noop.py <spec.json> <out.img>   (needs dtc on PATH)
"""
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DT_TABLE_MAGIC = 0xD7B7AB1E
ENTRY_SIZE = 32
PAGE_SIZE = 4096


def cells(values):
    return " ".join(f"0x{v:x}" for v in values)


def overlay_dts(spec, entry):
    props = [
        f'\tmodel = "{spec["model"]}";',
        "\tcompatible = " + ", ".join(f'"{c}"' for c in spec["compatible"]) + ";",
        f"\tqcom,msm-id = <{cells(entry['msm_id'])}>;",
        f"\tqcom,board-id = <{cells(entry['board_id'])}>;",
    ]
    if "pmic_id" in entry:
        props.append(f"\tqcom,pmic-id = <{cells(entry['pmic_id'])}>;")
        props.append(f"\tqcom,pmic-id-size = <{len(entry['pmic_id'])}>;")
    return "/dts-v1/;\n/plugin/;\n\n/ {\n" + "\n".join(props) + "\n};\n\n&soc {\n};\n"


def main():
    spec = json.loads(Path(sys.argv[1]).read_text())
    blobs = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, entry in enumerate(spec["entries"]):
            src = Path(tmp, f"e{i}.dts")
            src.write_text(overlay_dts(spec, entry))
            out = Path(tmp, f"e{i}.dtbo")
            subprocess.run(["dtc", "-q", "-@", "-I", "dts", "-O", "dtb", "-o", out, src], check=True)
            blobs.append(out.read_bytes())

    count = len(blobs)
    off = 32 + ENTRY_SIZE * count
    entries = b""
    data = b""
    for blob in blobs:
        # id/rev/custom stay 0, as in the stock tables: this ABL matches on
        # the properties inside each overlay.
        entries += struct.pack(">8I", len(blob), off + len(data), 0, 0, 0, 0, 0, 0)
        data += blob
    header = struct.pack(">8I", DT_TABLE_MAGIC, off + len(data), 32, ENTRY_SIZE,
                         count, 32, PAGE_SIZE, 0)
    Path(sys.argv[2]).write_bytes(header + entries + data)


if __name__ == "__main__":
    main()
