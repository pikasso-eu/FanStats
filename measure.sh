#!/bin/bash
# Baut fanlog und startet die Messung.
#   ./measure.sh                  -> 1 Messwert pro Sekunde, CSV im Projektordner
#   ./measure.sh --interval 2     -> alle 2 Sekunden
#   ./measure.sh -o /tmp/lauf.csv -> eigener Dateiname
set -euo pipefail
cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="$PWD/.cache/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/modulecache"
mkdir -p .cache/modulecache .cache/swiftpm .cache/config .cache/security

swift build -c release --product fanlog \
    --disable-sandbox \
    --cache-path "$PWD/.cache/swiftpm" \
    --config-path "$PWD/.cache/config" \
    --security-path "$PWD/.cache/security" \
    --scratch-path "$PWD/.build"

exec ".build/release/fanlog" "$@"
