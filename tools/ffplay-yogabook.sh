#!/usr/bin/bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPACK="$ROOT_DIR/atomisp-yu12-repack"

input="${1:-0}"
device="${2:-/dev/video0}"
fps="${FPS:-30}"

if [[ ! -x "$REPACK" ]]; then
    printf 'ERROR: %s is not built. Run: make -C %q\n' "$REPACK" "$ROOT_DIR" >&2
    exit 1
fi
command -v ffplay >/dev/null || {
    printf 'ERROR: ffplay is required\n' >&2
    exit 1
}

size="$($REPACK --probe --input "$input" "$device")"
[[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || {
    printf 'ERROR: unexpected probe result: %q\n' "$size" >&2
    exit 1
}

printf '==> input %s, negotiated %s YU12, display rate %s fps\n' "$input" "$size" "$fps" >&2
"$REPACK" --input "$input" "$device" | \
    ffplay -loglevel warning -f rawvideo -pixel_format yuv420p \
           -video_size "$size" -framerate "$fps" -i -
