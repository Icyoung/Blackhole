#!/bin/sh
set -eu

case "${PLATFORM_NAME:-}" in
  iphoneos*) ;;
  *) exit 0 ;;
esac

frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH:-Frameworks}"
if [ ! -d "$frameworks_dir" ]; then
  exit 0
fi

for framework in "$frameworks_dir"/*.framework; do
  [ -d "$framework" ] || continue
  binary_name="$(basename "$framework" .framework)"
  binary="$framework/$binary_name"
  [ -f "$binary" ] || continue

  identifier="$(/usr/bin/codesign -dv --verbose=4 "$binary" 2>&1 | /usr/bin/awk -F= '/^Identifier=/{id=$2} END{print id}')"
  case "$identifier" in
    io.flutter.flutter.native-assets.*) ;;
    *) continue ;;
  esac

  for arch in x86_64 i386; do
    if /usr/bin/lipo -info "$binary" | /usr/bin/grep -q "$arch"; then
      echo "Stripping $arch from $binary"
      /usr/bin/lipo "$binary" -remove "$arch" -output "$binary"
    fi
  done

  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-NO}" != "NO" ]; then
    echo "Re-signing $framework"
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements "$framework"
  fi
done

