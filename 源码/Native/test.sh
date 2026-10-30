#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/.build-native"
RES="$BUILD/1P备份助手.app/Contents/Resources"
[ -x "$RES/age" ] || { printf 'Run Native/build.sh first.\n' >&2; exit 1; }
swiftc -O -target arm64-apple-macosx26.0 -module-cache-path "$BUILD/ModuleCache" \
    -o "$BUILD/native-tests" "$HERE/Model.swift" "$HERE/KeyLocation.swift" "$HERE/KeyTransfer.swift" "$HERE/NativeTests.swift"
"$BUILD/native-tests" "$RES"
PYTHONDONTWRITEBYTECODE=1 TEST_RESOURCES="$RES" HELPER_SOURCE="$RES/helper.sh" ARCHIVE_TOOL="$RES/archive-tool" \
    python3 -m unittest discover -s "$ROOT/源码" -p test_helper.py -v
