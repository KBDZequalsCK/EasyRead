#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
STAGE_APP_DIR="$BUILD_DIR/EasyRead.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/EasyRead.app"
CONTENTS_DIR="$STAGE_APP_DIR/Contents"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$OUTPUT_DIR"

swiftc \
  -O \
  -target x86_64-apple-macos12.0 \
  -framework AppKit \
  -framework PDFKit \
  -framework WebKit \
  "$ROOT_DIR/Sources/IntelReader/MarkdownRenderer.swift" \
  "$ROOT_DIR/Sources/IntelReader/MOBIParser.swift" \
  "$ROOT_DIR/Sources/IntelReader/ZipArchive.swift" \
  "$ROOT_DIR/Sources/IntelReader/BookmarkStore.swift" \
  "$ROOT_DIR/Sources/IntelReader/ChapterHeading.swift" \
  "$ROOT_DIR/Sources/IntelReader/FB2Renderer.swift" \
  "$ROOT_DIR/Sources/IntelReader/ComicRenderer.swift" \
  "$ROOT_DIR/Sources/IntelReader/ComicReaderView.swift" \
  "$ROOT_DIR/Sources/IntelReader/RTFRenderer.swift" \
  "$ROOT_DIR/Sources/IntelReader/DOCXRenderer.swift" \
  "$ROOT_DIR/Sources/IntelReader/ReaderPagerScript.swift" \
  "$ROOT_DIR/Sources/IntelReader/BookCoverLoader.swift" \
  "$ROOT_DIR/Sources/IntelReader/ProLicense.swift" \
  "$ROOT_DIR/Sources/IntelReader/main.swift" \
  -o "$CONTENTS_DIR/MacOS/IntelReader"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ICON_SOURCE" ]]; then
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
fi
chmod +x "$CONTENTS_DIR/MacOS/IntelReader"
ditto "$STAGE_APP_DIR" "$APP_DIR"
# Keep EasyRead unsigned. An ad-hoc signature changes its cdhash on every
# rebuild, and macOS pins the saved Jianguoyun password to
# "cdhash:<cdhash>" in the keychain partition list, so each new build would
# be asked for the password again. Unsigned code gets the stable
# "unsigned:" partition instead, which survives every rebuild.
codesign --remove-signature "$APP_DIR/Contents/MacOS/IntelReader" 2>/dev/null || true
rm -rf "$BUILD_DIR"

echo "Built: $APP_DIR"
file "$APP_DIR/Contents/MacOS/IntelReader"
