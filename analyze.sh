#!/bin/bash
# Wertet eine fanlog-Messung aus.
#   ./analyze.sh fanstats-messung-....csv
#   ./analyze.sh messung.csv --ruhig 2      (strengere Lastgrenze)
set -euo pipefail
cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="$PWD/.cache/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/modulecache"
mkdir -p .cache/modulecache .cache/swiftpm .cache/config .cache/security

swift build -c release --product fananalyze \
    --disable-sandbox \
    --cache-path "$PWD/.cache/swiftpm" \
    --config-path "$PWD/.cache/config" \
    --security-path "$PWD/.cache/security" \
    --scratch-path "$PWD/.build"

exec ".build/release/fananalyze" "$@"
