#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/outputs/EasyRead.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
EXECUTABLE="$APP_DIR/Contents/MacOS/IntelReader"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easyread-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Missing app bundle: $APP_DIR" >&2
  echo "Run ./build.sh first." >&2
  exit 1
fi

ARCHS="$(lipo -archs "$EXECUTABLE")"
if [[ "$ARCHS" == *x86_64* && "$ARCHS" == *arm64* ]]; then
  ARCH_LABEL="Universal"
  DMG_PATH="$OUTPUT_DIR/EasyRead-Universal.dmg"
  VOLUME_NAME="EasyRead Universal"
elif [[ "$ARCHS" == *arm64* ]]; then
  ARCH_LABEL="ARM64"
  DMG_PATH="$OUTPUT_DIR/EasyRead-ARM64.dmg"
  VOLUME_NAME="EasyRead ARM64"
elif [[ "$ARCHS" == *x86_64* ]]; then
  ARCH_LABEL="Intel"
  DMG_PATH="$OUTPUT_DIR/EasyRead-Intel.dmg"
  VOLUME_NAME="EasyRead Intel"
else
  echo "Unsupported executable architecture: $ARCHS" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
ditto "$APP_DIR" "$STAGE_DIR/EasyRead.app"
ln -s /Applications "$STAGE_DIR/应用程序"
cp "$ROOT_DIR/DMG_README.txt" "$STAGE_DIR/使用说明.txt"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "Created ($ARCH_LABEL): $DMG_PATH"
file "$DMG_PATH"
