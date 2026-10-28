#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/outputs/简阅.app"
OUTPUT_DIR="$ROOT_DIR/outputs"
DMG_PATH="$OUTPUT_DIR/简阅-Intel.dmg"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easyread-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app bundle: $APP_DIR" >&2
  echo "Run ./build.sh first." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
ditto "$APP_DIR" "$STAGE_DIR/简阅.app"
ln -s /Applications "$STAGE_DIR/应用程序"
cp "$ROOT_DIR/DMG_README.txt" "$STAGE_DIR/使用说明.txt"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "简阅 Intel" \
  -srcfolder "$STAGE_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "Created: $DMG_PATH"
file "$DMG_PATH"
