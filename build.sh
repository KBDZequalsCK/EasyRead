#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
STAGE_APP_DIR="$BUILD_DIR/EasyRead.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/EasyRead.app"
CONTENTS_DIR="$STAGE_APP_DIR/Contents"
EXECUTABLE_NAME="IntelReader"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

# x86_64 (default) | arm64 | universal
ARCH="${ARCH:-x86_64}"
case "$ARCH" in
  x86_64|arm64|universal) ;;
  *)
    echo "Unsupported ARCH: $ARCH (expected x86_64, arm64, or universal)" >&2
    exit 1
    ;;
esac

SOURCES=(
  "$ROOT_DIR/Sources/IntelReader/MarkdownRenderer.swift"
  "$ROOT_DIR/Sources/IntelReader/MOBIParser.swift"
  "$ROOT_DIR/Sources/IntelReader/ZipArchive.swift"
  "$ROOT_DIR/Sources/IntelReader/BookmarkStore.swift"
  "$ROOT_DIR/Sources/IntelReader/ChapterHeading.swift"
  "$ROOT_DIR/Sources/IntelReader/FB2Renderer.swift"
  "$ROOT_DIR/Sources/IntelReader/ComicRenderer.swift"
  "$ROOT_DIR/Sources/IntelReader/ComicReaderView.swift"
  "$ROOT_DIR/Sources/IntelReader/RTFRenderer.swift"
  "$ROOT_DIR/Sources/IntelReader/DOCXRenderer.swift"
  "$ROOT_DIR/Sources/IntelReader/ReaderPagerScript.swift"
  "$ROOT_DIR/Sources/IntelReader/BookCoverLoader.swift"
  "$ROOT_DIR/Sources/IntelReader/main.swift"
)

build_slice() {
  local slice_arch="$1"
  local output="$2"
  swiftc \
    -O \
    -target "${slice_arch}-apple-macos12.0" \
    -framework AppKit \
    -framework PDFKit \
    -framework WebKit \
    "${SOURCES[@]}" \
    -o "$output"
}

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$OUTPUT_DIR"

EXECUTABLE="$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"
if [[ "$ARCH" == "universal" ]]; then
  X86_BINARY="$BUILD_DIR/IntelReader-x86_64"
  ARM_BINARY="$BUILD_DIR/IntelReader-arm64"
  build_slice x86_64 "$X86_BINARY"
  build_slice arm64 "$ARM_BINARY"
  lipo -create "$X86_BINARY" "$ARM_BINARY" -output "$EXECUTABLE"
else
  build_slice "$ARCH" "$EXECUTABLE"
fi

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

# Signing strategy:
# - x86_64 is kept unsigned. An unsigned process gets the stable "unsigned:"
#   keychain partition, and macOS pins the saved Jianguoyun password to it, so
#   saved WebDAV passwords survive rebuilds. An ad-hoc signature would change
#   the "cdhash:<cdhash>" partition on every build and ask for the password again.
# - arm64 must be signed, at least ad hoc, to launch on Apple Silicon. Sign the
#   whole bundle after assembly: the linker only signs the executable, and
#   codesign will not treat that as a valid bundle signature in place.
# - universal builds are signed the same way. Their cdhash changes on rebuild,
#   so switching between unsigned x86_64 and universal builds may prompt for
#   saved WebDAV passwords again.
if [[ "$ARCH" == "x86_64" ]]; then
  codesign --remove-signature "$APP_DIR/Contents/MacOS/IntelReader" 2>/dev/null || true
else
  codesign --force --sign - --timestamp=none "$APP_DIR"
  codesign --verify --arch arm64 "$APP_DIR"
fi

rm -rf "$BUILD_DIR"

echo "Built ($ARCH): $APP_DIR"
file "$APP_DIR/Contents/MacOS/IntelReader"
lipo -archs "$APP_DIR/Contents/MacOS/IntelReader"
