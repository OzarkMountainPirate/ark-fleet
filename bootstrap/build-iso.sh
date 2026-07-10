#!/usr/bin/env bash
#############################################################################
# build-iso.sh — bake preseed.cfg into a Debian netinst ISO for a fully
# unattended, walk-away USB install. Requires: xorriso, 7z (p7zip-full).
#
# Usage:
#   ./build-iso.sh debian-13.x.0-amd64-netinst.iso [out.iso]
#
# Then write the result to USB:
#   sudo dd if=ark-tiny-auto.iso of=/dev/sdX bs=4M status=progress oflag=sync
#############################################################################
set -euo pipefail

SRC="${1:?path to a Debian netinst ISO required}"
OUT="${2:-ark-tiny-auto.iso}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESEED="${PRESEED:-${HERE}/preseed.cfg}"

for bin in xorriso 7z; do
  command -v "$bin" >/dev/null || { echo "missing: $bin (apt install xorriso p7zip-full)"; exit 1; }
done
[ -f "$PRESEED" ] || { echo "preseed.cfg not found next to this script"; exit 1; }
grep -q 'REPLACE_ME' "$PRESEED" && { echo "ERROR: fill the REPLACE_ME markers in preseed.cfg first"; exit 1; }
if grep -q '__[A-Z_]*__' "$PRESEED"; then
  echo "ERROR: preseed still has unrendered __TOKENS__ (identity fields)." >&2
  echo "Render first via the netboot stack (netboot/setup.sh writes a fully" >&2
  echo "rendered copy to netboot/http/preseed.cfg), then:" >&2
  echo "  PRESEED=../netboot/http/preseed.cfg $0 <netinst.iso>" >&2
  exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo ">> extracting $SRC"
7z x -o"$WORK" "$SRC" >/dev/null

echo ">> injecting preseed + auto boot params"
cp "$PRESEED" "$WORK/preseed.cfg"

# Make the automated entry the default in both BIOS (isolinux) and UEFI (grub).
if [ -f "$WORK/isolinux/txt.cfg" ]; then
  sed -i '1i default auto' "$WORK/isolinux/txt.cfg" || true
fi
if [ -f "$WORK/boot/grub/grub.cfg" ]; then
  cat >> "$WORK/boot/grub/grub.cfg" <<'GRUB'

menuentry "ark-fleet unattended install" {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg vga=788 ---
    initrd   /install.amd/initrd.gz
}
set default="ark-fleet unattended install"
set timeout=3
GRUB
fi

echo ">> repacking -> $OUT"
xorriso -as mkisofs \
  -r -V 'ARK_TINY_AUTO' \
  -o "$OUT" \
  -J -joliet-long \
  -isohybrid-mbr "$WORK/isolinux/isohdpfx.bin" \
  -c isolinux/boot.cat -b isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  "$WORK" 2>/dev/null || {
    echo "NOTE: hybrid boot flags vary by Debian point release; if this fails,"
    echo "use the network method in README.md (preseed/url) instead."
    exit 1
  }
echo ">> done: $OUT"
