#!/usr/bin/env bash
set -euo pipefail
EXPECTED_RELEASE='7.2.4-200.fc44.x86_64'
[[ $EUID -eq 0 ]] || { echo 'ERROR: run with sudo' >&2; exit 1; }
[[ "$(uname -r)" == "$EXPECTED_RELEASE" ]] || { echo "ERROR: wrong kernel: $(uname -r)" >&2; exit 1; }

loaded() { lsmod | awk '{print $1}' | grep -qx "${1//-/_}"; }
remove_one() {
    local mod="$1"
    if loaded "$mod"; then
        modprobe -r "${mod//_/-}" 2>/dev/null || rmmod "${mod//-/_}"
    fi
}

# Tear down consumers before providers/replacement bridge.
remove_one atomisp
remove_one wv517s
remove_one ov8858
remove_one ov2740
remove_one atomisp_gmin_platform
remove_one ipu_bridge

# Restore Fedora's PM-only owner for the ISP when the real driver is absent.
modprobe intel_atomisp2_pm || true
lspci -nnk -s 00:03.0 || true
