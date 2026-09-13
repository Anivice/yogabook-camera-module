# Lenovo Yoga Book YB1-X91F — camera OOT backport for Fedora 44 / Linux 7.2.4

This is phase 2 of the AtomISP experiment. Phase 1 proved on the target YB1-X91F that
pristine Linux 7.2.4 `atomisp.ko` can build against Fedora's exact
`7.2.4-200.fc44.x86_64` ABI, load without unresolved symbols, bind PCI `8086:22b8`, and
create `/dev/media0` + `/dev/video0`. It then stopped at `no camera attached`, which is
the firmware/sensor-description boundary addressed here.

## Exact source policy

`build.sh` always starts from the official `linux-7.2.4.tar.xz` and verifies SHA-256:

`01710ee01737dac492f1bae52becd057e08d20d11589089aa06accff415c28dd`

It then downloads the pinned September 2, 2026 Yoga Book **v7 16-patch review series**
from Patchew. Before any source change it verifies the expected patch count and pinned
cover/first/last Message-IDs. Each decoded patch is run through `git apply --check`
against the exact 7.2.4 source at the state produced by the preceding patches. If any
hunk does not match cleanly, the build stops. There is no fuzzy patching and no 3-way
best guess.

Only the code/header paths needed by this external stack are applied. Upstream's
`MAINTAINERS`, Kconfig, and in-tree Makefile registration hunks are irrelevant for an
OOT replacement and are not applied.

The upstream v7 AtomISP DMI workaround names only `Lenovo YB1-X91L`. This project adds
a separate, explicit `Lenovo YB1-X91F` entry in
`patches/0001-yb1-x91f-dmi.patch`; it does not broaden the DMI match to every `X91`
string.

## Modules built

All replacements are compiled together against Fedora's prepared kernel tree and
`Module.symvers`:

- `ipu-bridge.ko`
- `atomisp_gmin_platform.ko`
- `atomisp.ko`
- `ov2740.ko` (front sensor / `OVTI2740`)
- `ov8858.ko` (rear sensor / `INT3477`)
- `wv517s.ko` (rear autofocus actuator)

Nothing is copied into `/lib/modules`, Fedora's installed modules are not overwritten,
and `depmod` is not run.

## Build

Use the environment containing the exact Fedora kernel-devel tree:

```bash
./build.sh
```

Important audit artifacts are left in `logs/`:

- `yogabook-camera-v7.mbox.sha256` — hash of the fetched review mbox
- `yogabook-v7-applied-subjects.txt` — all 16 verified subjects
- `yogabook-v7-code-only.diff` — upstream v7 code/header delta applied to 7.2.4
- `yogabook-v7-plus-x91f.diff` — same plus the explicit X91F DMI entry
- `oot-build-adaptations.diff` — local-header/Kbuild adaptations for external compilation
- `build-7.2.4-200.fc44.x86_64.log` — complete Kbuild/modpost output

If compilation or modpost reports an unavailable symbol, stop there and keep the log.
Do not force modpost warnings or add guessed exports.

## Load test

On the host:

```bash
sudo ./load-test.sh
sudo ./collect.sh
```

The loader first removes an earlier phase-1/phase-2 stack, uses
`intel_atomisp2_pm` once to recover the ISP from D3cold, verifies PCI vendor config
space reads as `8086`, then loads the **OOT** IPU bridge and AtomISP. Only after AtomISP
has attached the software firmware graph does it load the OV2740/OV8858 sensor modules
and WV517S actuator.

This order is deliberate: probing the sensor drivers before the bridge-created fwnodes
would test the wrong firmware graph.

Rollback:

```bash
sudo ./unload.sh
```

That removes the OOT stack and restores Fedora's `intel_atomisp2_pm` PCI owner.

## What success should look like

The most useful next evidence is no longer merely `/dev/video0`. Look for:

- IPU bridge finding `OVTI2740:00` and `INT3477:00`
- `ov2740` and `ov8858` bound under `/sys/bus/i2c/drivers/`
- V4L2 subdevice nodes
- a media graph containing both sensors
- no `no camera attached` line from AtomISP

`collect.sh` captures all of those plus `media-ctl -p` / `v4l2-ctl --list-devices` when
the corresponding userspace utilities are installed.
