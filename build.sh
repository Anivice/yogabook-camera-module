#!/usr/bin/bash  -x
set -euo pipefail

EXPECTED_RELEASE='7.2.4-200.fc44.x86_64'
UPSTREAM_VERSION='7.2.4'
UPSTREAM_URL='https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.4.tar.xz'
UPSTREAM_SHA256='01710ee01737dac492f1bae52becd057e08d20d11589089aa06accff415c28dd'
YB_V7_MBOX_URL='https://patchew.org/linux/cover.1788360629.git.mauriziocasciano7@gmail.com/mbox'
YB_V7_COVER_ID='cover.1788360629.git.mauriziocasciano7@gmail.com'
YB_V7_FIRST_ID='517c4f11075debaaa3eebc4e8bed574ac832565c.1788360629.git.mauriziocasciano7@gmail.com'
YB_V7_LAST_ID='bbd81ef43dfb8ad92572cdfb51ab2781e9a4cd02.1788360629.git.mauriziocasciano7@gmail.com'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$ROOT_DIR/cache"
SRC_DIR="$ROOT_DIR/src/linux-$UPSTREAM_VERSION-yogabook"
OUT_DIR="$ROOT_DIR/out/$EXPECTED_RELEASE"
LOG_DIR="$ROOT_DIR/logs"
MAIL_DIR="$ROOT_DIR/.work/yogabook-v7-mails"
DIFF_DIR="$ROOT_DIR/.work/yogabook-v7-diffs"
ARCHIVE="$CACHE_DIR/linux-$UPSTREAM_VERSION.tar.xz"
SERIES_MBOX="$CACHE_DIR/yogabook-camera-v7.mbox"
X91F_PATCH="$ROOT_DIR/patches/0001-yb1-x91f-dmi.patch"
NOTIFIER_PATCH="$ROOT_DIR/patches/0002-atomisp-notifier-lifecycle-backport.patch"

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info()  { printf '==> %s\n' "$*"; }

[[ "$(uname -r)" == "$EXPECTED_RELEASE" ]] || \
    fatal "running kernel is $(uname -r); expected exactly $EXPECTED_RELEASE"

for cmd in curl git make sha256sum tar modinfo awk sed grep diff; do
    command -v "$cmd" >/dev/null || fatal "$cmd is required"
done

if [[ -e "/lib/modules/$EXPECTED_RELEASE/build/Makefile" ]]; then
    KDIR="$(readlink -f "/lib/modules/$EXPECTED_RELEASE/build")"
elif [[ -e "/usr/src/kernels/$EXPECTED_RELEASE/Makefile" ]]; then
    KDIR="/usr/src/kernels/$EXPECTED_RELEASE"
else
    fatal "cannot find the prepared kernel-devel tree for $EXPECTED_RELEASE"
fi

[[ -r "$KDIR/Module.symvers" ]] || \
    fatal "$KDIR/Module.symvers is missing; modpost cannot validate Fedora's exported symbols/CRCs"
[[ -r "$KDIR/.config" ]] || fatal "$KDIR/.config is missing"
[[ -r "$X91F_PATCH" ]] || fatal "$X91F_PATCH is missing"
[[ -r "$NOTIFIER_PATCH" ]] || fatal "$NOTIFIER_PATCH is missing"

mkdir -p "$CACHE_DIR" "$OUT_DIR" "$LOG_DIR" "$ROOT_DIR/.work"
rm -rf "$MAIL_DIR" "$DIFF_DIR"
mkdir -p "$MAIL_DIR" "$DIFF_DIR"

info "target release: $EXPECTED_RELEASE"
info "kernel build tree: $KDIR"

# These are facilities selected/required by the in-tree drivers which this
# external build deliberately bypasses Kconfig to replace.  Refuse to build
# rather than guessing that a missing facility is available.
required_configs=(
    CONFIG_X86 CONFIG_EFI CONFIG_PCI CONFIG_ACPI CONFIG_PM CONFIG_COMMON_CLK
    CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CONTROLLER CONFIG_MEDIA_PCI_SUPPORT
    CONFIG_VIDEO_DEV CONFIG_VIDEO_V4L2_SUBDEV_API CONFIG_V4L2_FWNODE
    CONFIG_I2C CONFIG_REGMAP_I2C CONFIG_IOSF_MBI CONFIG_VIDEOBUF2_VMALLOC
    CONFIG_PMIC_OPREGION CONFIG_IPU_BRIDGE CONFIG_INTEL_SKL_INT3472
    CONFIG_VIDEO_OV2740 CONFIG_VIDEO_OV8858
)
missing=0
for sym in "${required_configs[@]}"; do
    line="$(grep -E "^${sym}=(y|m)$" "$KDIR/.config" || true)"
    if [[ -z "$line" ]]; then
        printf 'MISSING: %s\n' "$sym" >&2
        missing=1
    else
        printf 'config: %s\n' "$line"
    fi
done
(( missing == 0 )) || fatal "one or more required kernel facilities are absent from Fedora's target kernel"

if [[ ! -f "$ARCHIVE" ]]; then
    info "downloading upstream Linux $UPSTREAM_VERSION"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "$ARCHIVE.part" "$UPSTREAM_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
actual_sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$UPSTREAM_SHA256" ]] || \
    fatal "linux-$UPSTREAM_VERSION.tar.xz SHA-256 mismatch: got $actual_sha"
info "Linux $UPSTREAM_VERSION archive SHA-256 verified"

if [[ ! -f "$SERIES_MBOX" ]]; then
    info "downloading the pinned Yoga Book v7 review-series mbox"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "$SERIES_MBOX.part" "$YB_V7_MBOX_URL"
    mv "$SERIES_MBOX.part" "$SERIES_MBOX"
fi

# Patchew series URLs are keyed by the cover Message-ID.  Verify the fetched
# payload is exactly the expected 16-message v7 series before using any diff.
subject_count="$(grep -Ec '^Subject: \[PATCH v7 [0-9]{2}/16\]' "$SERIES_MBOX" || true)"
[[ "$subject_count" == 16 ]] || \
    fatal "unexpected Yoga Book mbox: found $subject_count v7 patch subjects, expected 16"
grep -Fq "<$YB_V7_COVER_ID>" "$SERIES_MBOX" || fatal "Yoga Book mbox cover Message-ID mismatch"
grep -Fq "<$YB_V7_FIRST_ID>" "$SERIES_MBOX" || fatal "Yoga Book mbox first-patch Message-ID mismatch"
grep -Fq "<$YB_V7_LAST_ID>" "$SERIES_MBOX" || fatal "Yoga Book mbox last-patch Message-ID mismatch"
sha256sum "$SERIES_MBOX" | tee "$LOG_DIR/yogabook-camera-v7.mbox.sha256"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
info "extracting the exact Linux $UPSTREAM_VERSION files touched by the OOT camera stack"
tar -xJf "$ARCHIVE" -C "$SRC_DIR" --strip-components=1 \
    "linux-$UPSTREAM_VERSION/drivers/media/i2c/ov2740.c" \
    "linux-$UPSTREAM_VERSION/drivers/media/i2c/ov8858.c" \
    "linux-$UPSTREAM_VERSION/drivers/media/pci/intel/ipu-bridge.c" \
    "linux-$UPSTREAM_VERSION/drivers/staging/media/atomisp" \
    "linux-$UPSTREAM_VERSION/include/media/ipu-bridge.h"

# Baseline the extracted 7.2.4 subset so every later source mutation can be
# audited with git diff.  Nothing from Fedora's source tree is edited.
git -C "$SRC_DIR" init -q
git -C "$SRC_DIR" config user.name 'Yoga Book OOT source verifier'
git -C "$SRC_DIR" config user.email 'noreply@localhost'
git -C "$SRC_DIR" add -A
git -C "$SRC_DIR" commit -qm "Linux $UPSTREAM_VERSION camera subset"

# Split and decode the upstream review mbox.  Apply only code/header paths
# required for the external modules; MAINTAINERS and in-tree Kconfig/Makefile
# registration are intentionally irrelevant to an OOT build.
git mailsplit -d4 -o"$MAIL_DIR" "$SERIES_MBOX" >/dev/null
mapfile -t mails < <(find "$MAIL_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${#mails[@]}" == 16 ]] || fatal "git mailsplit produced ${#mails[@]} messages, expected 16"

apply_args=(
    '--include=drivers/media/i2c/ov2740.c'
    '--include=drivers/media/i2c/ov8858.c'
    '--include=drivers/media/i2c/wv517s.c'
    '--include=drivers/media/pci/intel/ipu-bridge.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_cmd.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_cmd.h'
    '--include=drivers/staging/media/atomisp/pci/atomisp_csi2.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_csi2_bridge.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_ioctl.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_subdev.c'
    '--include=drivers/staging/media/atomisp/pci/atomisp_subdev.h'
    '--include=include/media/ipu-bridge.h'
)

: > "$LOG_DIR/yogabook-v7-applied-subjects.txt"
for idx in "${!mails[@]}"; do
    n=$((idx + 1))
    printf -v nn '%02d' "$n"
    mail="$MAIL_DIR/${mails[$idx]}"
    msg="$DIFF_DIR/$nn.msg"
    patch="$DIFF_DIR/$nn.patch"
    info_file="$DIFF_DIR/$nn.info"

    git mailinfo -k "$msg" "$patch" < "$mail" > "$info_file"
    subject="$(sed -n 's/^Subject: //p' "$info_file")"
    [[ "$subject" == "[PATCH v7 $nn/16]"* ]] || \
        fatal "message $nn has unexpected subject: $subject"
    printf '%s\n' "$subject" >> "$LOG_DIR/yogabook-v7-applied-subjects.txt"

    # --check first: if the exact 7.2.4 source no longer matches a hunk, stop
    # without fuzzing or inventing a backport.
    if ! git -C "$SRC_DIR" apply --check "${apply_args[@]}" "$patch"; then
        fatal "Yoga Book v7 patch $nn does not apply cleanly to exact Linux $UPSTREAM_VERSION source"
    fi
    git -C "$SRC_DIR" apply "${apply_args[@]}" "$patch"
done

[[ -f "$SRC_DIR/drivers/media/i2c/wv517s.c" ]] || fatal "v7 series did not create wv517s.c"

git -C "$SRC_DIR" add -A
git -C "$SRC_DIR" diff --cached --check

git -C "$SRC_DIR" diff --cached --binary > "$LOG_DIR/yogabook-v7-code-only.diff"

expected_paths="$LOG_DIR/yogabook-v7-expected-paths.txt"
actual_paths="$LOG_DIR/yogabook-v7-actual-paths.txt"
cat > "$expected_paths" <<'PATHS'
drivers/media/i2c/ov2740.c
drivers/media/i2c/ov8858.c
drivers/media/i2c/wv517s.c
drivers/media/pci/intel/ipu-bridge.c
drivers/staging/media/atomisp/pci/atomisp_cmd.c
drivers/staging/media/atomisp/pci/atomisp_cmd.h
drivers/staging/media/atomisp/pci/atomisp_csi2.c
drivers/staging/media/atomisp/pci/atomisp_csi2_bridge.c
drivers/staging/media/atomisp/pci/atomisp_ioctl.c
drivers/staging/media/atomisp/pci/atomisp_subdev.c
drivers/staging/media/atomisp/pci/atomisp_subdev.h
include/media/ipu-bridge.h
PATHS
git -C "$SRC_DIR" diff --cached --name-only | sort > "$actual_paths"
sort -o "$expected_paths" "$expected_paths"
diff -u "$expected_paths" "$actual_paths" || fatal "upstream series changed an unexpected code path"

# v7 scopes the broken OV2740 lane-count firmware override to X91L.  The test
# machine reports Lenovo YB1-X91F, so add a second explicit DMI entry without
# broadening the match to unrelated X91 strings.
info "applying the explicit YB1-X91F DMI override"
git -C "$SRC_DIR" apply --check "$X91F_PATCH" || \
    fatal "local X91F DMI patch no longer matches the verified v7 result"
git -C "$SRC_DIR" apply "$X91F_PATCH"
grep -Fq 'DMI_MATCH(DMI_PRODUCT_NAME, "Lenovo YB1-X91F")' \
    "$SRC_DIR/drivers/staging/media/atomisp/pci/atomisp_csi2_bridge.c" || \
    fatal "X91F DMI override was not applied"
grep -Fq 'DMI_MATCH(DMI_PRODUCT_NAME, "Lenovo YB1-X91L")' \
    "$SRC_DIR/drivers/staging/media/atomisp/pci/atomisp_csi2_bridge.c" || \
    fatal "upstream X91L DMI override unexpectedly disappeared"

git -C "$SRC_DIR" add -A
git -C "$SRC_DIR" diff --cached --check
git -C "$SRC_DIR" diff --cached --binary > "$LOG_DIR/yogabook-v7-plus-x91f.diff"

# Linux 7.2.4 registers AtomISP's V4L2 async notifier but does not unregister
# and clean it up on every teardown path.  The local patch is a narrowly
# re-contextualized backport of the upstream notifier-lifecycle fix.  Apply it
# explicitly here; merely shipping the patch file is not sufficient.
info "applying the AtomISP async-notifier lifecycle backport"
git -C "$SRC_DIR" apply --check "$NOTIFIER_PATCH" || \
    fatal "local notifier lifecycle patch no longer matches the verified v7+X91F result"
git -C "$SRC_DIR" apply "$NOTIFIER_PATCH"
grep -Fq 'v4l2_async_nf_unregister(&isp->notifier);' \
    "$SRC_DIR/drivers/staging/media/atomisp/pci/atomisp_v4l2.c" || \
    fatal "AtomISP notifier unregister fix was not applied"
grep -Fq 'v4l2_async_nf_cleanup(&isp->notifier);' \
    "$SRC_DIR/drivers/staging/media/atomisp/pci/atomisp_v4l2.c" || \
    fatal "AtomISP notifier cleanup fix was not applied"

git -C "$SRC_DIR" add -A
git -C "$SRC_DIR" diff --cached --check
git -C "$SRC_DIR" diff --cached --binary > "$LOG_DIR/yogabook-v7-plus-local-fixes.diff"

# ---- OOT-only build adaptations ------------------------------------------------
# The v7 header changes struct ipu_sensor.  Fedora's prepared tree still has the
# stock header, so the two users of <media/ipu-bridge.h> must include our local,
# patched copy.  Verify the exact include lines before replacing them.
IPU_C="$SRC_DIR/drivers/media/pci/intel/ipu-bridge.c"
ATOMISP_BRIDGE_C="$SRC_DIR/drivers/staging/media/atomisp/pci/atomisp_csi2_bridge.c"
[[ "$(grep -Fxc '#include <media/ipu-bridge.h>' "$IPU_C" || true)" == 1 ]] || \
    fatal "unexpected ipu-bridge.c include layout"
[[ "$(grep -Fxc '#include <media/ipu-bridge.h>' "$ATOMISP_BRIDGE_C" || true)" == 1 ]] || \
    fatal "unexpected atomisp_csi2_bridge.c include layout"
sed -i 's|^#include <media/ipu-bridge.h>$|#include "../../../../include/media/ipu-bridge.h"|' "$IPU_C"
sed -i 's|^#include <media/ipu-bridge.h>$|#include "../../../../../include/media/ipu-bridge.h"|' "$ATOMISP_BRIDGE_C"

ATOMISP_MAKEFILE="$SRC_DIR/drivers/staging/media/atomisp/Makefile"
grep -Fqx 'obj-$(CONFIG_VIDEO_ATOMISP) += atomisp.o' "$ATOMISP_MAKEFILE" || \
    fatal "unexpected AtomISP Makefile: atomisp target line differs from Linux $UPSTREAM_VERSION"
grep -Fqx 'obj-$(CONFIG_VIDEO_ATOMISP) += pci/atomisp_gmin_platform.o' "$ATOMISP_MAKEFILE" || \
    fatal "unexpected AtomISP Makefile: gmin target line differs from Linux $UPSTREAM_VERSION"
grep -Fqx 'atomisp = $(srctree)/drivers/staging/media/atomisp/' "$ATOMISP_MAKEFILE" || \
    fatal "unexpected AtomISP Makefile: source-root line differs from Linux $UPSTREAM_VERSION"
sed -i \
    -e 's|^obj-$(CONFIG_VIDEO_ATOMISP) += atomisp\.o$|obj-m += atomisp.o|' \
    -e 's|^obj-$(CONFIG_VIDEO_ATOMISP) += pci/atomisp_gmin_platform\.o$|obj-m += pci/atomisp_gmin_platform.o|' \
    -e 's|^atomisp = $(srctree)/drivers/staging/media/atomisp/$|atomisp = $(src)/|' \
    "$ATOMISP_MAKEFILE"

# External Kbuild files force exactly the replacement modules we need.  The
# in-tree Kconfig/Makefile registration is deliberately not used or modified.
cat > "$SRC_DIR/Kbuild" <<'KBUILD'
obj-m += drivers/media/i2c/
obj-m += drivers/media/pci/intel/
obj-m += drivers/staging/media/atomisp/
KBUILD
cat > "$SRC_DIR/drivers/media/i2c/Kbuild" <<'KBUILD'
obj-m += ov2740.o
obj-m += ov8858.o
obj-m += wv517s.o
KBUILD
cat > "$SRC_DIR/drivers/media/pci/intel/Kbuild" <<'KBUILD'
obj-m += ipu-bridge.o
KBUILD

# Keep a complete audit diff, including only the small OOT build adaptations
# on top of the verified v7+X91F source changes.
git -C "$SRC_DIR" diff --binary > "$LOG_DIR/oot-build-adaptations.diff"

BUILD_LOG="$LOG_DIR/build-$EXPECTED_RELEASE.log"
info "building the complete replacement media stack against Fedora's exact Module.symvers"
set +e
make -C "$KDIR" M="$SRC_DIR" -j"$(nproc)" V=1 modules 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}
set -e
if (( rc != 0 )); then
    printf '\n=== likely symbol/modpost diagnostics ===\n' >&2
    grep -E 'ERROR: modpost:|undefined!|undefined symbol|Unknown symbol|modpost:' "$BUILD_LOG" >&2 || true
    printf '\nFull build log: %s\n' "$BUILD_LOG" >&2
    exit "$rc"
fi

modules=(
    "drivers/media/i2c/ov2740.ko:ov2740.ko"
    "drivers/media/i2c/ov8858.ko:ov8858.ko"
    "drivers/media/i2c/wv517s.ko:wv517s.ko"
    "drivers/media/pci/intel/ipu-bridge.ko:ipu-bridge.ko"
    "drivers/staging/media/atomisp/pci/atomisp_gmin_platform.ko:atomisp_gmin_platform.ko"
    "drivers/staging/media/atomisp/atomisp.ko:atomisp.ko"
)
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
for entry in "${modules[@]}"; do
    src_rel="${entry%%:*}"
    out_name="${entry#*:}"
    src_ko="$SRC_DIR/$src_rel"
    [[ -f "$src_ko" ]] || fatal "build returned success but $src_rel is missing"
    install -m 0644 "$src_ko" "$OUT_DIR/$out_name"
done

for ko in "$OUT_DIR"/*.ko; do
    info "$(basename "$ko")"
    modinfo "$ko" | tee "$LOG_DIR/$(basename "$ko").modinfo"
    vermagic="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
    [[ "$vermagic" == "$EXPECTED_RELEASE" ]] || \
        fatal "$(basename "$ko") vermagic starts with '$vermagic', expected '$EXPECTED_RELEASE'"
done

printf '\nSUCCESS: Yoga Book v7 + X91F + notifier-lifecycle external-module build completed.\n'
printf 'Modules: %s\n' "$OUT_DIR"
printf 'Source diff: %s\n' "$LOG_DIR/yogabook-v7-plus-local-fixes.diff"
printf 'Next: sudo %s/load-test.sh\n' "$ROOT_DIR"
