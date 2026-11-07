#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT_DIR/Resources/ScreenRecall.icon"
if (( $# > 1 )); then
  echo "usage: $0 [NEW_OUTPUT_DIR]" >&2
  exit 2
fi

if [[ ! -f "$ICON_DIR/icon.json" ]]; then
  echo "missing Icon Composer document: $ICON_DIR" >&2
  exit 2
fi

if (( $# == 1 )); then
  OUTPUT_DIR="$1"
  if [[ -z "$OUTPUT_DIR" ]] || ! mkdir -- "$OUTPUT_DIR"; then
    echo "output directory must be a new path with an existing parent: $OUTPUT_DIR" >&2
    exit 1
  fi
else
  mkdir -p "$ROOT_DIR/Local/IconBuild"
  OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/Local/IconBuild/run.XXXXXXXX")"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/screenrecall-catalog.XXXXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
TEMP_CATALOG="$TEMP_ROOT/Support.xcassets"
mkdir "$TEMP_CATALOG"
cat > "$TEMP_CATALOG/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

xcrun actool \
  --compile "$OUTPUT_DIR" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 27.0 \
  --app-icon ScreenRecall \
  --output-partial-info-plist "$OUTPUT_DIR/partial.plist" \
  --notices \
  --warnings \
  "$TEMP_CATALOG" \
  "$ICON_DIR"

for artifact in Assets.car ScreenRecall.icns partial.plist; do
  if [[ ! -f "$OUTPUT_DIR/$artifact" ]]; then
    echo "actool did not produce: $OUTPUT_DIR/$artifact" >&2
    exit 1
  fi
done

printf 'output=%s\n' "$OUTPUT_DIR"
printf 'assets=%s\n' "$OUTPUT_DIR/Assets.car"
printf 'icns=%s\n' "$OUTPUT_DIR/ScreenRecall.icns"
printf 'plist=%s\n' "$OUTPUT_DIR/partial.plist"
