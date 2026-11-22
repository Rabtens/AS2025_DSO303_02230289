#!/usr/bin/env bash
# Package a source directory into a zip whose ROOT is that directory's contents.
# Usage: usms-pack-source.sh <source-dir> <output-zip>
set -uo pipefail

SRC="${1:-}"
OUT="${2:-}"
if [ -z "$SRC" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <source-dir> <output-zip>" >&2
  exit 2
fi
if [ ! -d "$SRC" ]; then
  echo "not a directory: $SRC" >&2
  exit 2
fi

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"

if command -v zip >/dev/null 2>&1; then
  ( cd "$SRC" && zip -r -q "$OUT_ABS" . -x '*.bak' -x 'dist/*' )
  echo "packed with zip"
else
  python3 - "$SRC" "$OUT_ABS" << 'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in sorted(dirs) if d != "dist"]
        for f in sorted(files):
            if f.endswith(".bak"):
                continue
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src))
PY
  echo "packed with python3 zipfile"
fi

echo "--- archive contents ---"
if command -v unzip >/dev/null 2>&1; then
  unzip -l "$OUT_ABS"
else
  python3 -c 'import sys,zipfile;[print(n) for n in zipfile.ZipFile(sys.argv[1]).namelist()]' "$OUT_ABS"
fi
