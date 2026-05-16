#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/assets/brand/app_icon.svg"
BRAND_MARK_SVG="$ROOT_DIR/assets/brand/brand_mark.svg"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/blackhole-icons.XXXXXX")"

trap 'rm -rf "$TMP_DIR"' EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to generate app icons" >&2
    exit 1
  fi
}

require_command rsvg-convert
require_command magick

render_flat_png() {
  local output="$1"
  local pixels="$2"
  local tmp_file="$TMP_DIR/flat-${pixels}.png"

  mkdir -p "$(dirname "$output")"
  rsvg-convert --width "$pixels" --height "$pixels" "$SOURCE_SVG" --output "$tmp_file"
  magick "$tmp_file" -background white -alpha remove -alpha off "$output"
}

render_desktop_png() {
  local output="$1"
  local pixels="$2"
  local flat_file="$TMP_DIR/desktop-flat-${pixels}.png"
  local mask_file="$TMP_DIR/desktop-mask-${pixels}.png"
  local radius=$((pixels * 224 / 1024))

  mkdir -p "$(dirname "$output")"
  rsvg-convert --width "$pixels" --height "$pixels" "$SOURCE_SVG" --output "$flat_file"
  magick -size "${pixels}x${pixels}" xc:none \
    -fill white \
    -draw "roundrectangle 0,0,$((pixels - 1)),$((pixels - 1)),$radius,$radius" \
    "$mask_file"
  magick "$flat_file" "$mask_file" -alpha off -compose CopyOpacity -composite "$output"
}

write_landing_brand_mark() {
  cp "$BRAND_MARK_SVG" "$ROOT_DIR/internal/landing/brand-mark.svg"
}

write_landing_macos_svg() {
  cat >"$ROOT_DIR/internal/landing/app_icon_macos.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Blackhole app icon">
  <defs>
    <clipPath id="upper-half">
      <rect x="0" y="0" width="1024" height="614.4"/>
    </clipPath>
    <clipPath id="desktop-mask">
      <rect x="0" y="0" width="1024" height="1024" rx="224" ry="224"/>
    </clipPath>
  </defs>
  <g clip-path="url(#desktop-mask)">
    <rect width="1024" height="1024" fill="#ffffff"/>
    <circle cx="512" cy="512" r="358" fill="none" stroke="#0a0a0a" stroke-width="48"/>
    <line x1="169" y1="614.4" x2="855" y2="614.4" stroke="#0a0a0a" stroke-width="48"/>
    <circle cx="512" cy="512" r="128" fill="#0a0a0a" clip-path="url(#upper-half)"/>
  </g>
</svg>
SVG
}

generate_voyager_ios() {
  local icon_dir="$ROOT_DIR/voyager/ios/Runner/Assets.xcassets/AppIcon.appiconset"

  render_flat_png "$icon_dir/Icon-App-20x20@1x.png" 20
  render_flat_png "$icon_dir/Icon-App-20x20@2x.png" 40
  render_flat_png "$icon_dir/Icon-App-20x20@3x.png" 60
  render_flat_png "$icon_dir/Icon-App-29x29@1x.png" 29
  render_flat_png "$icon_dir/Icon-App-29x29@2x.png" 58
  render_flat_png "$icon_dir/Icon-App-29x29@3x.png" 87
  render_flat_png "$icon_dir/Icon-App-40x40@1x.png" 40
  render_flat_png "$icon_dir/Icon-App-40x40@2x.png" 80
  render_flat_png "$icon_dir/Icon-App-40x40@3x.png" 120
  render_flat_png "$icon_dir/Icon-App-60x60@2x.png" 120
  render_flat_png "$icon_dir/Icon-App-60x60@3x.png" 180
  render_flat_png "$icon_dir/Icon-App-76x76@1x.png" 76
  render_flat_png "$icon_dir/Icon-App-76x76@2x.png" 152
  render_flat_png "$icon_dir/Icon-App-83.5x83.5@2x.png" 167
  render_flat_png "$icon_dir/Icon-App-1024x1024@1x.png" 1024
}

generate_voyager_android() {
  render_flat_png "$ROOT_DIR/voyager/android/app/src/main/res/mipmap-mdpi/ic_launcher.png" 48
  render_flat_png "$ROOT_DIR/voyager/android/app/src/main/res/mipmap-hdpi/ic_launcher.png" 72
  render_flat_png "$ROOT_DIR/voyager/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png" 96
  render_flat_png "$ROOT_DIR/voyager/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png" 144
  render_flat_png "$ROOT_DIR/voyager/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" 192
}

generate_voyager_macos() {
  local icon_dir="$ROOT_DIR/voyager/macos/Runner/Assets.xcassets/AppIcon.appiconset"

  render_desktop_png "$icon_dir/app_icon_16.png" 16
  render_desktop_png "$icon_dir/app_icon_32.png" 32
  render_desktop_png "$icon_dir/app_icon_64.png" 64
  render_desktop_png "$icon_dir/app_icon_128.png" 128
  render_desktop_png "$icon_dir/app_icon_256.png" 256
  render_desktop_png "$icon_dir/app_icon_512.png" 512
  render_desktop_png "$icon_dir/app_icon_1024.png" 1024
}

generate_horizon_macos_status_bar() {
  local icon_dir="$ROOT_DIR/horizon/macos/Runner/Assets.xcassets/StatusBarIcon.imageset"

  rsvg-convert --width 18 --height 18 "$BRAND_MARK_SVG" --output "$icon_dir/statusbar_18.png"
  rsvg-convert --width 36 --height 36 "$BRAND_MARK_SVG" --output "$icon_dir/statusbar_36.png"
}

generate_voyager_windows() {
  local icon_path="$ROOT_DIR/voyager/windows/runner/resources/app_icon.ico"
  local size
  local ico_inputs=()

  for size in 16 32 48 256; do
    local png="$TMP_DIR/windows-${size}.png"
    render_desktop_png "$png" "$size"
    ico_inputs+=("$png")
  done

  magick "${ico_inputs[@]}" "$icon_path"
}

generate_voyager_linux() {
  render_desktop_png "$ROOT_DIR/voyager/linux/runner/icons/voyager-64.png" 64
  render_desktop_png "$ROOT_DIR/voyager/linux/runner/icons/voyager-128.png" 128
  render_desktop_png "$ROOT_DIR/voyager/linux/runner/icons/voyager-256.png" 256
  render_desktop_png "$ROOT_DIR/voyager/linux/runner/icons/voyager.png" 512
}

generate_voyager_web() {
  render_flat_png "$ROOT_DIR/voyager/web/favicon.png" 16
  render_flat_png "$ROOT_DIR/voyager/web/icons/Icon-192.png" 192
  render_flat_png "$ROOT_DIR/voyager/web/icons/Icon-512.png" 512
  render_flat_png "$ROOT_DIR/voyager/web/icons/Icon-maskable-192.png" 192
  render_flat_png "$ROOT_DIR/voyager/web/icons/Icon-maskable-512.png" 512

  local ico_16="$TMP_DIR/voyager-web-favicon-16.png"
  local ico_32="$TMP_DIR/voyager-web-favicon-32.png"
  local ico_48="$TMP_DIR/voyager-web-favicon-48.png"
  render_flat_png "$ico_16" 16
  render_flat_png "$ico_32" 32
  render_flat_png "$ico_48" 48
  magick "$ico_16" "$ico_32" "$ico_48" "$ROOT_DIR/voyager/web/favicon.ico"
}

generate_landing() {
  cp "$SOURCE_SVG" "$ROOT_DIR/internal/landing/app_icon.svg"
  cp "$SOURCE_SVG" "$ROOT_DIR/internal/landing/favicon.svg"
  write_landing_macos_svg
  write_landing_brand_mark

  render_flat_png "$ROOT_DIR/internal/landing/favicon.png" 32

  local ico_16="$TMP_DIR/landing-favicon-16.png"
  local ico_32="$TMP_DIR/landing-favicon-32.png"
  local ico_48="$TMP_DIR/landing-favicon-48.png"
  render_flat_png "$ico_16" 16
  render_flat_png "$ico_32" 32
  render_flat_png "$ico_48" 48
  magick "$ico_16" "$ico_32" "$ico_48" "$ROOT_DIR/internal/landing/favicon.ico"
}

generate_voyager_ios
generate_voyager_android
generate_voyager_macos
generate_horizon_macos_status_bar
generate_voyager_windows
generate_voyager_linux
generate_voyager_web
generate_landing

echo "Generated app icons from $SOURCE_SVG"
