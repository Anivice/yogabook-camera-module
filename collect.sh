#!/usr/bin/env bash
set -u
EXPECTED_RELEASE='7.2.4-200.fc44.x86_64'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
OUT="$LOG_DIR/report-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

echo '=== date/kernel ==='
date -Ins
uname -a

echo '=== DMI ==='
cat /sys/class/dmi/id/sys_vendor 2>/dev/null
cat /sys/class/dmi/id/product_name 2>/dev/null

echo '=== AtomISP PCI ==='
lspci -nnk -s 00:03.0 2>/dev/null || lspci -nnk | grep -A5 -Ei 'imaging|camera|multimedia'

echo '=== driver symlink ==='
readlink -f /sys/bus/pci/devices/0000:00:03.0/driver 2>/dev/null || true

echo '=== target config ==='
KDIR="/lib/modules/$EXPECTED_RELEASE/build"
[[ -r "$KDIR/.config" ]] || KDIR="/usr/src/kernels/$EXPECTED_RELEASE"
grep -E 'CONFIG_(INTEL_ATOMISP|VIDEO_ATOMISP|INTEL_ATOMISP2_PM|IPU_BRIDGE|INTEL_SKL_INT3472|VIDEO_OV2740|VIDEO_OV8858|REGMAP_I2C|MEDIA_CONTROLLER|VIDEO_DEV|PMIC_OPREGION|IOSF_MBI|VIDEOBUF2_VMALLOC)' "$KDIR/.config" 2>/dev/null || true

echo '=== built module metadata ==='
for name in ipu-bridge atomisp_gmin_platform atomisp ov2740 ov8858 wv517s; do
    ko="$ROOT_DIR/out/$EXPECTED_RELEASE/$name.ko"
    [[ -f "$ko" ]] || continue
    echo "--- $ko"
    modinfo "$ko" || true
done

echo '=== nodes ==='
ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || true

echo '=== modules ==='
lsmod | grep -Ei 'atomisp|ov2740|ov8858|wv517|ipu|int3472|v4l2|videobuf' || true

echo '=== ACPI camera objects ==='
find /sys/bus/acpi/devices -maxdepth 1 -printf '%f\n' 2>/dev/null | grep -E 'INT3477|OVTI2740' || true

echo '=== I2C camera bindings ==='
for drv in ov2740 ov8858 wv517s; do
    if [[ -d "/sys/bus/i2c/drivers/$drv" ]]; then
        echo "--- $drv"
        find "/sys/bus/i2c/drivers/$drv" -maxdepth 1 -type l -printf '%f -> %l\n' 2>/dev/null || true
    fi
done

echo '=== media topology ==='
if command -v media-ctl >/dev/null 2>&1 && [[ -e /dev/media0 ]]; then
    media-ctl -d /dev/media0 -p || true
else
    echo '(media-ctl unavailable or /dev/media0 absent)'
fi

echo '=== v4l2 devices ==='
if command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl --list-devices || true
else
    echo '(v4l2-ctl unavailable)'
fi

echo '=== relevant dmesg ==='
dmesg | grep -Ei 'atomisp|isp2401|22b8|ov2740|ov8858|OVTI2740|INT3477|wv517|ipu.bridge|camera|firmware|Unknown symbol' | tail -n 700 || true

echo "=== report: $OUT ==="
