#!/usr/bin/env bash
set -euo pipefail
EXPECTED_RELEASE='7.2.4-200.fc44.x86_64'
[[ $EUID -eq 0 ]] || { echo 'ERROR: run with sudo' >&2; exit 1; }
[[ "$(uname -r)" == "$EXPECTED_RELEASE" ]] || { echo "ERROR: wrong kernel: $(uname -r)" >&2; exit 1; }

if dmesg 2>/dev/null | grep -Eq 'RIP: .*v4l2_async_(unbind_subdev_one|__v4l2_async_nf_register)'; then
    echo 'ERROR: this boot has already taken a V4L2-async camera oops; reboot before touching the camera module stack again' >&2
    exit 1
fi

loaded() { lsmod | awk '{print $1}' | grep -qx "${1//-/_}"; }
remove_one() {
    local mod="$1"
    if loaded "$mod"; then
        modprobe -r "${mod//_/-}" 2>/dev/null || rmmod "${mod//-/_}"
    fi
}

# V4L2 async teardown is callback-driven: unregister the leaf subdevices
# while the AtomISP notifier (and its ops table in atomisp.ko) is still alive.
# Removing atomisp first can leave an async connection that later calls an
# unbind callback through text/rodata belonging to the already-unloaded module.
remove_one wv517s
remove_one ov8858
remove_one ov2740
remove_one atomisp
remove_one atomisp_gmin_platform
remove_one ipu_bridge

# Restore Fedora's PM-only owner for the ISP when the real driver is absent.
modprobe intel_atomisp2_pm || true
lspci -nnk -s 00:03.0 || true
