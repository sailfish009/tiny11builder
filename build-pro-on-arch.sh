#!/usr/bin/env bash
# Keep only Windows 11 Pro in the installer; does NOT remove Windows components.
# A solid install.esd over 4 GiB requires an NTFS WoeUSB target, NOT FAT32.
set -euo pipefail

usage() {
  echo "Usage: $0 INPUT.iso OUTPUT.iso [USB_CAPACITY_BYTES]" >&2
  echo "Example: $0 Windows11_Client_x64_en-us_26300_9457.iso Windows11_Pro_only.iso 7982915584" >&2
  exit 2
}
[[ $# -ge 2 && $# -le 3 ]] || usage
for cmd in sudo mount umount rsync wimlib-imagex xorriso python3 du mktemp; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
iso=$(realpath "$1")
out=$(realpath -m "$2")
[[ -f "$iso" && "$iso" != "$out" && ! -e "$out" ]] || { echo 'Input must exist; output must be new and different.' >&2; exit 1; }
capacity=${3:-7982915584}
[[ "$capacity" =~ ^[0-9]+$ ]] || usage
[[ -d "$(dirname "$out")" ]] || { echo 'Output directory does not exist.' >&2; exit 1; }
work=$(mktemp -d -p "$(dirname "$out")" .win11-pro-build.XXXXXXXX)
mkdir "$work/mount" "$work/tree"
mounted=0
cleanup_mount() {
  if (( mounted )); then sudo umount "$work/mount" || echo "WARNING: unmount $work/mount manually" >&2; fi
}
trap cleanup_mount EXIT
# sudo is used ONLY for read-only loop mounting and unmounting the source ISO.
sudo mount -t udf -o loop,ro "$iso" "$work/mount"
mounted=1
src="$work/mount"
[[ -f "$src/sources/boot.wim" && -f "$src/boot/etfsboot.com" && -f "$src/efi/microsoft/boot/efisys.bin" ]] || {
  echo 'Expected Windows x64 installation/boot files not found in ISO.' >&2; exit 1;
}
if [[ -f "$src/sources/install.wim" ]]; then
  image="$src/sources/install.wim"
elif [[ -f "$src/sources/install.esd" ]]; then
  image="$src/sources/install.esd"
else
  echo 'Neither sources/install.wim nor sources/install.esd exists.' >&2; exit 1
fi
# Read edition metadata without extracting the whole Windows image.  Match exactly,
# never silently select Pro N, Pro for Workstations, or another edition.
index=$(python3 - "$image" <<'PY'
import subprocess, sys, xml.etree.ElementTree as ET
xml = subprocess.check_output(['wimlib-imagex', 'info', sys.argv[1], '--xml'])
root = ET.fromstring(xml)
found = []
for image in root.findall('.//IMAGE'):
    name = image.findtext('NAME', '').strip()
    display = image.findtext('DISPLAYNAME', '').strip()
    number = image.get('INDEX')
    print(f'Index {number}: {name} ({display})', file=sys.stderr)
    if name == 'Windows 11 Pro' or display == 'Windows 11 Pro':
        found.append(number)
if len(found) != 1:
    sys.exit(f'Expected exactly one Windows 11 Pro edition, found {len(found)}; no changes made to ISO/USB')
print(found[0])
PY
)
echo "Exporting Pro index $index to compressed install.esd (this can take a while)..."
rsync -a --exclude='/sources/install.wim' --exclude='/sources/install.esd' "$src/" "$work/tree/"
# Installation media may mark directories read-only; the new ESD must be writable.
chmod u+w "$work/tree/sources"
wimlib-imagex export "$image" "$index" "$work/tree/sources/install.esd" --compress=LZMS --solid
esd_bytes=$(stat -c %s "$work/tree/sources/install.esd")
if (( esd_bytes > 4294967295 )); then
  echo "IMPORTANT: install.esd is $esd_bytes bytes (>4 GiB)." >&2
  echo 'WoeUSB silently skips oversized .esd on FAT32. Use --target-filesystem NTFS with --device.' >&2
fi
# This approximates WoeUSB's space requirement; allow room for filesystem metadata.
bytes=$(du -sb --apparent-size "$work/tree" | awk '{print $1}')
echo "Installer tree: $bytes bytes; USB usable capacity: $capacity bytes"
if (( bytes + 67108864 > capacity )); then
  echo "Installer does not fit with 64 MiB safety margin. Work tree kept at: $work/tree" >&2
  exit 1
fi
# Retain both BIOS and UEFI El Torito boot images.  -iso-level 3 supports large files.
xorriso -as mkisofs -iso-level 3 -J -joliet-long -V 'WIN11_PRO' \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -o "$out" "$work/tree"
iso_bytes=$(stat -c %s "$out")
echo "Created $out ($iso_bytes bytes)"
if (( iso_bytes > capacity )); then
  echo "WARNING: output ISO itself is larger than USB capacity; do not run WoeUSB yet." >&2
fi
echo "Verify ISO content and bootability before using it. Build tree retained at $work/tree"
