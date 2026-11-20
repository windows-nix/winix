"""Patch an IVRS ACPI table so VFIO works: drop the IVMD unity/exclusion blocks.

Kernel 7 honours the firmware's IVMD entries: every device listed in one is
refused an unmanaged (VFIO) IOMMU domain — "Firmware has requested this device
have a 1:1 IOMMU mapping". Boards ship IVMD-RANGE blocks covering whole PCI
bus ranges just to protect a few SMM scratch pages, which takes the GPU and
the passed-through NVMe controller hostage. Dropping them loses that SMM
exclusion and nothing else: the Linux DMA API keeps using translated domains,
only VFIO unmanaged attach was blocked.

Usage: patch-ivrs.py <orig-table> <out-table>

  - removes every IVMD-RANGE (type 0x22) block, logging device and phys range
  - bumps OEM Revision by one: the kernel applies an initrd table override
    only when its revision is higher than the firmware table's
  - fixes the checksum

Run at build time from nixos/windows-vm/default.nix; the input is the raw
dump of this board's firmware table (`cp /sys/firmware/acpi/tables/IVRS`,
needs root — see windows-vm.ivrsDump). After a BIOS update, re-dump and
re-check what gets dropped.
"""
import struct
import sys


def devname(s):
    return f"{s >> 8:02x}:{(s >> 3) & 0x1f:02x}.{s & 7}"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1:3]
    d = bytearray(open(src, "rb").read())
    if d[:4] != b"IVRS":
        sys.exit(f"patch-ivrs: {src} is not an IVRS table")
    tlen = struct.unpack_from("<I", d, 4)[0]
    if tlen > len(d):
        sys.exit(f"patch-ivrs: bad length {tlen} for {len(d)} bytes")

    # ACPI header is 48 bytes here (36 + IvInfo + reserved); blocks follow.
    off, out, dropped = 48, bytearray(d[:48]), []
    while off < tlen:
        t = d[off]
        blen = struct.unpack_from("<H", d, off + 2)[0]
        if blen == 0 or off + blen > tlen:
            sys.exit(f"patch-ivrs: bad block at {off}")
        if t == 0x22:  # IVMD-RANGE: unity/exclusion for devid..aux
            devid, aux = struct.unpack_from("<HH", d, off + 4)
            start, end = struct.unpack_from("<QQ", d, off + 16)
            dropped.append(f"IVMD-RANGE {devname(devid)}..{devname(aux)} "
                           f"phys 0x{start:x}-0x{end:x} (flags 0x{d[off+1]:02x})")
        else:
            out += d[off:off + blen]
        off += blen
    if off != tlen:
        sys.exit("patch-ivrs: block walk desynced")

    struct.pack_into("<I", out, 4, len(out))
    rev = struct.unpack_from("<I", out, 24)[0]
    struct.pack_into("<I", out, 24, rev + 1)
    out[9] = 0
    out[9] = (0x100 - (sum(out) & 0xFF)) & 0xFF
    open(dst, "wb").write(bytes(out))
    for x in dropped:
        print(f"patch-ivrs: dropping {x}", file=sys.stderr)
    print(f"patch-ivrs: {src} {tlen} B -> {dst} {len(out)} B, "
          f"OEM revision {rev} -> {rev + 1}, {len(dropped)} IVMD block(s) removed",
          file=sys.stderr)


if __name__ == "__main__":
    main()
