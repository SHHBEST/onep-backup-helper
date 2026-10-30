#!/bin/bash
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$ROOT/.build-native"
APP="$BUILD/1P备份助手.app"
RES="$APP/Contents/Resources"
VENDOR="$ROOT/vendor/age/darwin-arm64"
mkdir -p "$APP/Contents/MacOS" "$RES" "$BUILD/AppIcon.iconset"
swiftc -O -target arm64-apple-macosx26.0 -module-cache-path "$BUILD/ModuleCache" \
    -o "$APP/Contents/MacOS/1PBackup" "$HERE/App.swift" "$HERE/Model.swift" "$HERE/KeyLocation.swift" "$HERE/KeyTransfer.swift" "$HERE/Views.swift"
clang -O2 -Wall -Wextra -Werror -target arm64-apple-macosx26.0 \
    "$HERE/ArchiveTool.c" -larchive -o "$RES/archive-tool"
swiftc -O -module-cache-path "$BUILD/ModuleCache" -o "$BUILD/make-icon" "$HERE/Icon.swift"
"$BUILD/make-icon" "$BUILD/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD/AppIcon.iconset" -o "$RES/AppIcon.icns"
(cd "$VENDOR" && /usr/bin/shasum -a 256 -c SHA256SUMS)
cp "$VENDOR/age" "$VENDOR/age-keygen" "$VENDOR/LICENSE-age.txt" "$RES/"
cp "$ROOT/源码/helper.sh" "$RES/helper.sh"
cp "$ROOT/使用说明.md" "$RES/使用说明.md"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
info = {
    'CFBundleExecutable':'1PBackup', 'CFBundleIdentifier':'.'.join(['app','onep','vault']),
    'CFBundleName':'1P备份助手', 'CFBundleDisplayName':'1P备份助手',
    'CFBundlePackageType':'APPL', 'CFBundleInfoDictionaryVersion':'6.0',
    'CFBundleShortVersionString':'2.2', 'CFBundleVersion':'4',
    'CFBundleIconFile':'AppIcon', 'CFBundleDevelopmentRegion':'zh_CN',
    'CFBundleLocalizations':['zh_CN'], 'LSMinimumSystemVersion':'26.0',
    'NSHighResolutionCapable':True, 'NSSupportsAutomaticTermination':False,
    'CFBundleDocumentTypes':[{'CFBundleTypeName':'Backup file', 'CFBundleTypeRole':'Viewer',
                             'LSHandlerRank':'Alternate', 'LSItemContentTypes':['public.data','public.folder']}],
}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f)
PY
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
printf '\nBuilt: %s\n' "$APP"
