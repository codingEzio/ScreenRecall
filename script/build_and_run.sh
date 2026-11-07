#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---verify}"
case "$MODE" in
  --verify|run|--build-only|--unsigned-only|--demo|--logs|--telemetry|--debug) ;;
  *) echo "Usage: $0 [--verify|--build-only|--unsigned-only|--demo|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac
# Keep build products, fixture catalogs and rollback bundles outside source.
SOURCE_ID="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c1-12)"
BUILD_ROOT="${SCREENRECALL_BUILD_ROOT:-$HOME/Library/Caches/ScreenRecall/$SOURCE_ID}"
SUPPORT_ROOT="$HOME/Library/Application Support/ScreenRecall"
case "$BUILD_ROOT/" in
  "$ROOT_DIR/"*) echo "Build root must be outside the source tree" >&2; exit 1 ;;
  /*) ;;
  *) echo "Build root must be absolute" >&2; exit 1 ;;
esac
mkdir -p "$BUILD_ROOT" "$SUPPORT_ROOT"
# The bundled notices below are pinned to the reviewed encoder release.
WEBP_VERSION="$(pkg-config --modversion libwebp)"
if [[ "$WEBP_VERSION" != "1.6.0" ]]; then
  echo "libwebp 1.6.0 is required; review notices before changing the pinned version" >&2
  exit 1
fi
swift build -c release -j 4 --scratch-path "$BUILD_ROOT/swift"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_ROOT/swift" --show-bin-path)"
STAGE="$BUILD_ROOT/Stage/ScreenRecall.app"
if [[ "$MODE" == "--unsigned-only" ]]; then
  STAGE="$BUILD_ROOT/Unsigned/ScreenRecall.app"
  if [[ -e "$STAGE" ]]; then
    echo "unsigned candidate already exists; use a fresh source copy: $STAGE" >&2
    exit 1
  fi
fi
BUNDLE="$HOME/Applications/ScreenRecall.app"
# Source candidates carry the exact reviewed font and all its notices.
FONT_DEFAULT_ROOT="$ROOT_DIR/Dependencies/DeparturePixelZh"
FONT_BUILD_ROOT="${DEPARTURE_PIXEL_ZH_BUILD_ROOT:-$FONT_DEFAULT_ROOT}"
FONT_FILE="$FONT_BUILD_ROOT/DeparturePixelZhCompact-Regular.ttf"
FONT_SHA256="74adf4919c690e61aa7bdd4c369a6f5c84029413a7da5e85d687ea7fa6b502e7"
FONT_LICENSE_DIR="$FONT_BUILD_ROOT/Licenses"
FONT_BUNDLE_REPORT="$BUILD_ROOT/CompactFontMigration/staged-font-bundle.json"
if [[ ! -f "$FONT_FILE" || ! -f "$FONT_BUILD_ROOT/OFL.txt" || ! -f "$FONT_BUILD_ROOT/NOTICE.md" || ! -f "$FONT_BUILD_ROOT/provenance.json" ]]; then
  echo "missing DeparturePixelZh Compact build output under: $FONT_BUILD_ROOT" >&2
  exit 1
fi
if [[ ! -d "$FONT_LICENSE_DIR" ]]; then
  FONT_LICENSE_DIR="$FONT_BUILD_ROOT/licenses"
fi
if [[ ! -d "$FONT_LICENSE_DIR" ]]; then
  echo "missing font license directory under: $FONT_BUILD_ROOT" >&2
  exit 1
fi
if [[ "$(shasum -a 256 "$FONT_FILE" | awk '{print $1}')" != "$FONT_SHA256" ]]; then
  echo "DeparturePixelZh Compact SHA-256 does not match the reviewed build" >&2
  exit 1
fi
mkdir -p "$STAGE/Contents/MacOS"
mkdir -p "$STAGE/Contents/Resources"
cp "$BIN_DIR/ScreenRecall" "$STAGE/Contents/MacOS/ScreenRecall"
ICON_RUN="$(mktemp -d "$BUILD_ROOT/ScreenRecall.icon.XXXXXXXX")"
ICON_BUILD="$ICON_RUN/IconBuild"
./script/build_icon.sh "$ICON_BUILD" > "$ICON_RUN/icon-build.log"
cp "$ICON_BUILD/Assets.car" "$ICON_BUILD/ScreenRecall.icns" "$STAGE/Contents/Resources/"
cp -R "$ROOT_DIR"/Resources/Localization/*.lproj "$STAGE/Contents/Resources/"
mkdir -p "$STAGE/Contents/Resources/Fonts"
cp "$FONT_FILE" "$STAGE/Contents/Resources/Fonts/DeparturePixelZhCompact-Regular.ttf"
cp "$FONT_BUILD_ROOT/OFL.txt" "$STAGE/Contents/Resources/OFL.txt"
cp "$FONT_BUILD_ROOT/NOTICE.md" "$STAGE/Contents/Resources/NOTICE.md"
cp -R "$FONT_LICENSE_DIR" "$STAGE/Contents/Resources/Licenses"
cp "$FONT_BUILD_ROOT/provenance.json" "$STAGE/Contents/Resources/provenance.json"
mkdir -p "$(dirname "$FONT_BUNDLE_REPORT")"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScreenRecall</string>
<key>CFBundleIdentifier</key><string>com.alex.ScreenRecall</string>
<key>CFBundleName</key><string>ScreenRecall</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.9</string>
<key>CFBundleVersion</key><string>24</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array/>
</dict></plist>
PLIST
# An explicit data root is an installation choice, never a source default.
DATA_DIRECTORY="${SCREENRECALL_DATA_DIRECTORY:-}"
if [[ -z "$DATA_DIRECTORY" && -f "$BUNDLE/Contents/Info.plist" ]]; then
  DATA_DIRECTORY="$(/usr/libexec/PlistBuddy -c 'Print :RecallLocalDirectory' "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -n "$DATA_DIRECTORY" ]]; then
  case "$DATA_DIRECTORY/" in
    "$ROOT_DIR/"*) echo "Data root must be outside the source tree" >&2; exit 1 ;;
    /*) ;;
    *) echo "Data root must be absolute" >&2; exit 1 ;;
  esac
  /usr/libexec/PlistBuddy -c "Add :RecallLocalDirectory string $DATA_DIRECTORY" "$STAGE/Contents/Info.plist"
fi
for localization in "$ROOT_DIR"/Resources/Localization/*.lproj; do
  localization_code="$(basename "$localization" .lproj)"
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $localization_code" "$STAGE/Contents/Info.plist"
done
/usr/libexec/PlistBuddy -c "Merge '$ICON_BUILD/partial.plist'" "$STAGE/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGE/Contents/Info.plist"
# The icon output is now incorporated; failures before this point retain it for diagnosis.
rm -rf -- "$ICON_RUN"
# Unsigned preparation never reads the signing file or queries the keychain.
if [[ "$MODE" != "--unsigned-only" ]]; then
  SIGNING_FILE="$SUPPORT_ROOT/signing-identity"
  SIGNING_IDENTITY="${SCREENRECALL_SIGN_IDENTITY:-}"
  if [[ -z "$SIGNING_IDENTITY" && -f "$SIGNING_FILE" ]]; then
      SIGNING_IDENTITY="$(cat "$SIGNING_FILE")"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
      SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development:|Developer ID Application:/ {print $2; exit}')"
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
      SIGNING_IDENTITY="-"
      echo "No development identity found; ad-hoc updates may require renewed Screen Recording permission."
  fi
fi
# Ship the encoder in the bundle: recording never invokes a Homebrew CLI at runtime.
WEBP_LIB_DIR="$(pkg-config --variable=libdir libwebp)"
FRAMEWORKS="$STAGE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
cp "$WEBP_LIB_DIR/libwebp.7.dylib" "$FRAMEWORKS/libwebp.7.dylib"
cp "$WEBP_LIB_DIR/libsharpyuv.0.dylib" "$FRAMEWORKS/libsharpyuv.0.dylib"
chmod u+w "$FRAMEWORKS/libwebp.7.dylib" "$FRAMEWORKS/libsharpyuv.0.dylib"
/usr/bin/install_name_tool -change "$WEBP_LIB_DIR/libwebp.7.dylib" \
  "@executable_path/../Frameworks/libwebp.7.dylib" "$STAGE/Contents/MacOS/ScreenRecall"
/usr/bin/install_name_tool -change "@rpath/libsharpyuv.0.dylib" \
  "@loader_path/libsharpyuv.0.dylib" "$FRAMEWORKS/libwebp.7.dylib"
/usr/bin/install_name_tool -id "@rpath/libwebp.7.dylib" "$FRAMEWORKS/libwebp.7.dylib"
/usr/bin/install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$FRAMEWORKS/libsharpyuv.0.dylib"
PUBLIC_DOCS="$ROOT_DIR/distribution/public"
if [[ ! -f "$PUBLIC_DOCS/LICENSE" ]]; then PUBLIC_DOCS="$ROOT_DIR"; fi
# BEGIN PUBLIC LICENSE PACKAGING — also exercised with a disposable fixture.
for notice in COPYING PATENTS; do
    cp "$ROOT_DIR/Licenses/libwebp-1.6.0-$notice.txt" "$STAGE/Contents/Resources/libwebp-$notice.txt"
done
cp "$PUBLIC_DOCS/LICENSE" "$STAGE/Contents/Resources/ScreenRecall-LICENSE.txt"
cp "$PUBLIC_DOCS/LICENSE_SCOPE.md" "$STAGE/Contents/Resources/ScreenRecall-LICENSE-SCOPE.md"
cp "$PUBLIC_DOCS/ARTWORK.md" "$STAGE/Contents/Resources/ScreenRecall-ARTWORK.md"
cp "$PUBLIC_DOCS/FONT_NOTICE_CORRECTIONS.md" "$STAGE/Contents/Resources/FONT-NOTICE-CORRECTIONS.md"
cp "$PUBLIC_DOCS/Licenses/CC-BY-4.0.txt" "$STAGE/Contents/Resources/CC-BY-4.0.txt"
# END PUBLIC LICENSE PACKAGING
if [[ "$MODE" == "--unsigned-only" ]]; then
    swift "$ROOT_DIR/script/verify_compact_font_bundle.swift" "$STAGE" "$FONT_BUNDLE_REPORT"
    echo "Prepared without signing, installation or launch: $STAGE"
    exit 0
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$FRAMEWORKS/libsharpyuv.0.dylib"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$FRAMEWORKS/libwebp.7.dylib"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$STAGE"
/usr/bin/codesign --verify --strict "$STAGE"
swift "$ROOT_DIR/script/verify_compact_font_bundle.swift" "$STAGE" "$FONT_BUNDLE_REPORT"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    (umask 077; printf '%s\n' "$SIGNING_IDENTITY" > "$SIGNING_FILE")
fi
if [[ "$MODE" == "--build-only" ]]; then
    echo "Built and signed: $STAGE"
    exit 0
fi
# Demo is a separate staged app and never replaces or stops the daily app.
if [[ "$MODE" == "--demo" ]]; then
    "$BIN_DIR/RecallCheck" --fixture "$BUILD_ROOT/Demo"
    /usr/bin/open -n "$STAGE" --args --library "$BUILD_ROOT/Demo"
    echo "Synthetic demo launched: $STAGE"
    exit 0
fi
# Finish building and signing before the brief swap; stop only this installation.
INSTALLED_PID="$(/usr/bin/pgrep -f "^$BUNDLE/Contents/MacOS/ScreenRecall$" || true)"
if [[ -n "$INSTALLED_PID" ]]; then
    /bin/kill -TERM "$INSTALLED_PID"
    for attempt in {1..50}; do
        /bin/kill -0 "$INSTALLED_PID" 2>/dev/null || break
        /bin/sleep 0.1
    done
    if /bin/kill -0 "$INSTALLED_PID" 2>/dev/null; then
        echo "ScreenRecall is still exiting; current app preserved." >&2
        exit 1
    fi
fi
mkdir -p "$(dirname "$BUNDLE")"
ROLLBACK_DIR="$(mktemp -d "$BUILD_ROOT/ScreenRecall.rollback.XXXXXX")"
if [[ -d "$BUNDLE" ]]; then
    mv "$BUNDLE" "$ROLLBACK_DIR/ScreenRecall.app"
fi
echo "Previous app retained in: $ROLLBACK_DIR"
mv "$STAGE" "$BUNDLE"
/usr/bin/open -n "$BUNDLE"
case "$MODE" in
    --logs|--telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.alex.ScreenRecall"' ;;
    --debug) /usr/bin/lldb -n ScreenRecall ;;
    --verify)
      for attempt in {1..50}; do
        /usr/bin/pgrep -f "^$BUNDLE/Contents/MacOS/ScreenRecall$" >/dev/null && { echo "ScreenRecall launched."; exit 0; }
        /bin/sleep 0.1
      done
      echo "Installed app did not remain running; rollback retained: $ROLLBACK_DIR" >&2
      exit 1 ;;
esac
