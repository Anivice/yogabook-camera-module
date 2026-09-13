#!/usr/bin/env bash
set -euo pipefail

EXPECTED_RELEASE='7.2.4-200.fc44.x86_64'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT_DIR/out/$EXPECTED_RELEASE"
LOG_DIR="$ROOT_DIR/logs"

ATOMISP_KO="$OUT_DIR/atomisp.ko"
GMIN_KO="$OUT_DIR/atomisp_gmin_platform.ko"
IPU_KO="$OUT_DIR/ipu-bridge.ko"
OV2740_KO="$OUT_DIR/ov2740.ko"
OV8858_KO="$OUT_DIR/ov8858.ko"
WV517S_KO="$OUT_DIR/wv517s.ko"

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info()  { printf '==> %s\n' "$*"; }
loaded() { lsmod | awk '{print $1}' | grep -qx "${1//-/_}"; }

[[ $EUID -eq 0 ]] || fatal "run this script with sudo"
[[ "$(uname -r)" == "$EXPECTED_RELEASE" ]] || \
    fatal "running kernel is $(uname -r); expected exactly $EXPECTED_RELEASE"
for ko in "$ATOMISP_KO" "$GMIN_KO" "$IPU_KO" "$OV2740_KO" "$OV8858_KO" "$WV517S_KO"; do
    [[ -f "$ko" ]] || fatal "$ko missing; run ./build.sh first"
done
mkdir -p "$LOG_DIR"

if dmesg 2>/dev/null | grep -Eq 'RIP: .*v4l2_async_(unbind_subdev_one|__v4l2_async_nf_register)'; then
    fatal "this boot has already taken a V4L2-async camera oops; reboot before unloading/reloading the camera stack"
fi

product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
case "$product" in
    'Lenovo YB1-X91F'|'Lenovo YB1-X91L') ;;
    *) fatal "this build is scoped to Lenovo YB1-X91F/X91L; DMI product is '$product'" ;;
esac
info "DMI product: $product"

if command -v mokutil >/dev/null 2>&1; then
    info "Secure Boot state"
    mokutil --sb-state || true
fi

BDF="$(lspci -Dnnd 8086:22b8 2>/dev/null | awk 'NR==1 {print $1}')"
[[ -n "$BDF" ]] || fatal "PCI 8086:22b8 was not found"
[[ "$BDF" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[[:xdigit:]]$ ]] || \
    fatal "unexpected full PCI BDF '$BDF'"
DEV="/sys/bus/pci/devices/$BDF"
[[ -d "$DEV" ]] || fatal "PCI sysfs device $DEV missing"

info "removing any previous phase-1/phase-2 camera modules"
# Keep AtomISP resident until every async sensor/lens subdevice has
# unregistered. v4l2_async_unregister_subdev() may call the managing
# notifier's ->unbind callback, whose ops table lives in atomisp.ko.
for mod in wv517s ov8858 ov2740 atomisp atomisp_gmin_platform ipu_bridge; do
    if loaded "$mod"; then
        info "removing $mod"
        modprobe -r "${mod//_/-}" 2>/dev/null || rmmod "${mod//-/_}" || \
            fatal "could not remove loaded module $mod"
    fi
done

# Hand the PCI function through the platform PM driver once, exactly as in the
# successful phase-1 test, so an ISP left in D3cold gets its hardware-specific
# resume callback before AtomISP claims it.
owner=""
[[ -L "$DEV/driver" ]] && owner="$(basename "$(readlink -f "$DEV/driver")")"
if [[ -z "$owner" ]]; then
    info "temporarily loading intel_atomisp2_pm to recover/power the ISP"
    modprobe intel_atomisp2_pm || fatal "could not load intel_atomisp2_pm"
    sleep 0.2
    [[ -L "$DEV/driver" ]] && owner="$(basename "$(readlink -f "$DEV/driver")")"
fi
if [[ "$owner" == intel_atomisp2_pm ]]; then
    if [[ -w "$DEV/power/control" ]]; then
        info "forcing ISP runtime-PM control to 'on' before removing intel_atomisp2_pm"
        printf 'on\n' > "$DEV/power/control"
        sleep 0.2
        printf 'runtime_status: '
        cat "$DEV/power/runtime_status" 2>/dev/null || true
    fi
    info "removing intel_atomisp2_pm so atomisp can claim 8086:22b8"
    modprobe -r intel_atomisp2_pm
    owner=""
    [[ -L "$DEV/driver" ]] && owner="$(basename "$(readlink -f "$DEV/driver")")"
fi
[[ -z "$owner" ]] || fatal "PCI device is still bound to '$owner'; refusing to force-unbind it"

if command -v setpci >/dev/null 2>&1; then
    vendor_now="$(setpci -s "$BDF" VENDOR_ID 2>/dev/null || true)"
    info "PCI config-space vendor read after PM handoff: ${vendor_now:-<failed>}"
    [[ "${vendor_now,,}" == 8086 ]] || \
        fatal "ISP PCI config space is inaccessible after PM handoff"
fi

load_declared_deps() {
    local ko="$1" dep deps normalized
    deps="$(modinfo -F depends "$ko" 2>/dev/null || true)"
    [[ -n "$deps" ]] || return 0
    IFS=',' read -r -a list <<< "$deps"
    for dep in "${list[@]}"; do
        dep="${dep// /}"
        [[ -n "$dep" ]] || continue
        normalized="${dep//_/-}"
        case "$normalized" in
            atomisp-gmin-platform|ipu-bridge|ov2740|ov8858|wv517s) continue ;;
        esac
        if ! loaded "$dep"; then
            info "modprobe dependency: $dep"
            modprobe "$dep"
        fi
    done
}

# The bridge must precede AtomISP because atomisp imports INTEL_IPU_BRIDGE.
# Sensors intentionally come *after* AtomISP: atomisp's bridge initialization
# first attaches the synthetic firmware graph/link frequencies to the ACPI
# sensor nodes, then loading the I2C sensor drivers probes against that graph.
load_declared_deps "$IPU_KO"
info "insmod ipu-bridge.ko"
insmod "$IPU_KO"

load_declared_deps "$GMIN_KO"
load_declared_deps "$ATOMISP_KO"
info "insmod atomisp_gmin_platform.ko"
insmod "$GMIN_KO"
info "insmod atomisp.ko"
insmod "$ATOMISP_KO"
sleep 0.5

for ko in "$OV2740_KO" "$OV8858_KO" "$WV517S_KO"; do
    load_declared_deps "$ko"
    info "insmod $(basename "$ko")"
    insmod "$ko"
done

sleep 1
printf '\n=== PCI binding ===\n'
lspci -nnk -s "${BDF#0000:}" || true
printf '\n=== media/video/subdev nodes ===\n'
ls -l /dev/video* /dev/media* /dev/v4l-subdev* 2>/dev/null || printf '(none)\n'
printf '\n=== loaded camera modules ===\n'
lsmod | grep -Ei 'atomisp|ov2740|ov8858|wv517|ipu|int3472|v4l2|videobuf' || true
printf '\n=== I2C camera bindings ===\n'
for drv in ov2740 ov8858 wv517s; do
    if [[ -d "/sys/bus/i2c/drivers/$drv" ]]; then
        printf -- '--- %s\n' "$drv"
        find "/sys/bus/i2c/drivers/$drv" -maxdepth 1 -type l -printf '%f -> %l\n' 2>/dev/null || true
    fi
done
printf '\n=== recent relevant kernel log ===\n'
dmesg | grep -Ei 'atomisp|isp2401|22b8|ov2740|ov8858|OVTI2740|INT3477|wv517|ipu.bridge|camera|firmware' | tail -n 350 || true

printf '\nIf this reached the end, run sudo ./collect.sh and keep its report.\n'
