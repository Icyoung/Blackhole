#!/usr/bin/env bash
set -euo pipefail

if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1" >&2; }
log_ok() { printf "${GREEN}[OK]${NC} %s\n" "$1" >&2; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }
log_step() { printf "\n${BLUE}=== %s ===${NC}\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VOYAGER_DIR="$REPO_ROOT/voyager"
OUTPUT_DIR="$VOYAGER_DIR/output"

TEAM_ID="${VOYAGER_APPSTORE_TEAM_ID:-J3N394FG8K}"
APP_BUNDLE_ID="${VOYAGER_IOS_BUNDLE_ID:-dev.icyou.blackhole.voyager}"
TUNNEL_BUNDLE_ID="${VOYAGER_IOS_TUNNEL_BUNDLE_ID:-dev.icyou.blackhole.voyager.tunnel}"
SIGNING_STYLE="${VOYAGER_APPSTORE_SIGNING_STYLE:-automatic}"
EXPORT_METHOD="${VOYAGER_APPSTORE_EXPORT_METHOD:-app-store}"

API_KEY_ID="${VOYAGER_APPSTORE_API_KEY_ID:-${APPSTORE_API_KEY_ID:-}}"
API_ISSUER_ID="${VOYAGER_APPSTORE_API_ISSUER_ID:-${APPSTORE_API_ISSUER_ID:-}}"
API_KEY_PATH="${VOYAGER_APPSTORE_API_KEY_PATH:-${APPSTORE_API_KEY_PATH:-}}"

SKIP_CLEAN=false
SKIP_POD=false
BUILD_ONLY=false
VALIDATE_ONLY=false
UPLOAD_ONLY_IPA=""
BUILD_NAME=""
BUILD_NUMBER=""
BUILT_IPA_PATH=""

show_help() {
  cat <<EOF
Voyager App Store upload script

Usage:
  $0 [options]

Options:
  --build-name <version>       Override CFBundleShortVersionString, e.g. 1.0.1
  --build-number <number>      Override CFBundleVersion, e.g. 3
  --output-dir <dir>           Output directory, default: voyager/output
  --skip-clean                 Skip flutter clean
  --skip-pod                   Skip pod install
  --build-only                 Build IPA but do not upload
  --validate-only              Validate IPA with App Store Connect instead of uploading
  --upload-only <ipa>          Upload or validate an existing IPA
  -h, --help                   Show this help

Environment:
  VOYAGER_APPSTORE_API_KEY_ID       Required for upload
  VOYAGER_APPSTORE_API_ISSUER_ID    Required for upload
  VOYAGER_APPSTORE_API_KEY_PATH     Optional, defaults to ~/.private_keys/AuthKey_<key-id>.p8
  VOYAGER_APPSTORE_TEAM_ID          Default: $TEAM_ID
  VOYAGER_APPSTORE_SIGNING_STYLE    automatic|manual, default: automatic
  VOYAGER_IOS_PROFILE_NAME          Required when signing style is manual
  VOYAGER_IOS_TUNNEL_PROFILE_NAME   Required when signing style is manual
  IOS_KEYCHAIN_PATH                 Optional keychain path for non-interactive signing
  IOS_KEYCHAIN_PASSWORD             Optional keychain password

Examples:
  $0
  $0 --build-number 3
  $0 --build-only --skip-clean
  $0 --upload-only voyager/output/voyager_0516_v1.0.0_2.ipa
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build-name)
      BUILD_NAME="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --skip-clean)
      SKIP_CLEAN=true
      shift
      ;;
    --skip-pod)
      SKIP_POD=true
      shift
      ;;
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    --upload-only)
      UPLOAD_ONLY_IPA="${2:-}"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      show_help
      exit 1
      ;;
  esac
done

case "$SIGNING_STYLE" in
  automatic|manual) ;;
  *)
    log_error "VOYAGER_APPSTORE_SIGNING_STYLE must be automatic or manual, got: $SIGNING_STYLE"
    exit 1
    ;;
esac

if [ -n "$UPLOAD_ONLY_IPA" ] && [ "$BUILD_ONLY" = true ]; then
  log_error "--upload-only and --build-only cannot be used together"
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "$1 is required but was not found"
    exit 1
  fi
}

version_name() {
  local version_line
  version_line="$(grep '^version:' "$VOYAGER_DIR/pubspec.yaml" | head -1 | awk '{print $2}')"
  printf "%s" "${BUILD_NAME:-${version_line%%+*}}"
}

version_code() {
  local version_line
  version_line="$(grep '^version:' "$VOYAGER_DIR/pubspec.yaml" | head -1 | awk '{print $2}')"
  printf "%s" "${BUILD_NUMBER:-${version_line#*+}}"
}

check_env() {
  log_step "Environment"

  if [ "$(uname)" != "Darwin" ]; then
    log_error "iOS App Store builds must run on macOS"
    exit 1
  fi

  require_command flutter
  require_command xcodebuild
  require_command xcrun
  require_command security

  if [ "$SKIP_POD" = false ]; then
    require_command pod
  fi

  if [ ! -d "$VOYAGER_DIR" ]; then
    log_error "Voyager directory not found: $VOYAGER_DIR"
    exit 1
  fi

  log_ok "Flutter: $(flutter --version | head -1)"
  log_ok "Xcode: $(xcodebuild -version | head -1)"
  log_ok "Version: $(version_name) ($(version_code))"
  log_ok "Signing style: $SIGNING_STYLE"
}

prepare_keychain() {
  log_step "Keychain"

  local keychain_path
  keychain_path="${IOS_KEYCHAIN_PATH:-$(security default-keychain -d user 2>/dev/null | tr -d '"' | xargs || true)}"

  if [ -z "$keychain_path" ] || [ ! -f "$keychain_path" ]; then
    log_warn "No usable keychain found; codesign may prompt or fail in SSH"
    return 0
  fi

  log_info "Using keychain: $keychain_path"

  local keychain_password="${IOS_KEYCHAIN_PASSWORD:-}"
  if [ -z "$keychain_password" ] && [ -t 0 ]; then
    read -r -s -p "Keychain password: " keychain_password
    printf "\n"
  fi

  if [ -z "$keychain_password" ]; then
    log_warn "IOS_KEYCHAIN_PASSWORD is empty; skipping keychain unlock"
    return 0
  fi

  security unlock-keychain -p "$keychain_password" "$keychain_path"
  security set-keychain-settings -lut 21600 "$keychain_path"

  if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null 2>&1; then
    log_ok "Keychain unlocked and private key ACL prepared"
  else
    log_warn "Keychain unlocked, but set-key-partition-list failed"
  fi
}

prepare_project() {
  log_step "Prepare"

  mkdir -p "$OUTPUT_DIR"
  cd "$VOYAGER_DIR"

  if [ "$SKIP_CLEAN" = true ]; then
    log_warn "Skipping flutter clean"
  else
    log_info "flutter clean"
    flutter clean
  fi

  log_info "flutter pub get"
  flutter pub get

  if [ "$SKIP_POD" = true ]; then
    log_warn "Skipping pod install"
  else
    log_info "pod install"
    (cd ios && pod install)
  fi
}

write_export_options() {
  local plist_path="$1"

  if [ "$SIGNING_STYLE" = "manual" ]; then
    local app_profile="${VOYAGER_IOS_PROFILE_NAME:-}"
    local tunnel_profile="${VOYAGER_IOS_TUNNEL_PROFILE_NAME:-}"

    if [ -z "$app_profile" ] || [ -z "$tunnel_profile" ]; then
      log_error "Manual signing requires VOYAGER_IOS_PROFILE_NAME and VOYAGER_IOS_TUNNEL_PROFILE_NAME"
      exit 1
    fi

    cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$APP_BUNDLE_ID</key>
    <string>$app_profile</string>
    <key>$TUNNEL_BUNDLE_ID</key>
    <string>$tunnel_profile</string>
  </dict>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST
  else
    cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST
  fi
}

build_ipa() {
  log_step "Build IPA"

  cd "$VOYAGER_DIR"

  local export_plist="$VOYAGER_DIR/ios/ExportOptions.appstore.generated.plist"
  write_export_options "$export_plist"

  local flutter_args=(
    build ipa
    --release
    --export-options-plist="$export_plist"
  )

  if [ -n "$BUILD_NAME" ]; then
    flutter_args+=(--build-name "$BUILD_NAME")
  fi
  if [ -n "$BUILD_NUMBER" ]; then
    flutter_args+=(--build-number "$BUILD_NUMBER")
  fi

  if ! flutter "${flutter_args[@]}"; then
    log_warn "flutter build ipa failed; trying xcodebuild -exportArchive from existing archive"
    local archive_path="$VOYAGER_DIR/build/ios/archive/Runner.xcarchive"
    if [ ! -d "$archive_path" ]; then
      log_error "Archive not found: $archive_path"
      exit 1
    fi
    rm -rf "$VOYAGER_DIR/build/ios/ipa"
    xcodebuild -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$VOYAGER_DIR/build/ios/ipa" \
      -exportOptionsPlist "$export_plist"
  fi

  local src
  src="$(find "$VOYAGER_DIR/build/ios/ipa" -name "*.ipa" -type f | head -1)"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    log_error "IPA not found under $VOYAGER_DIR/build/ios/ipa"
    exit 1
  fi

  local dest="$OUTPUT_DIR/voyager_$(date +%m%d)_v$(version_name)_$(version_code).ipa"
  cp "$src" "$dest"
  rm -f "$export_plist"

  log_ok "IPA: $dest"
  log_ok "Size: $(du -h "$dest" | cut -f1)"
  BUILT_IPA_PATH="$dest"
}

check_api_key() {
  if [ -z "$API_KEY_ID" ] || [ -z "$API_ISSUER_ID" ]; then
    log_error "App Store Connect API key id and issuer id are required"
    log_info "Set VOYAGER_APPSTORE_API_KEY_ID and VOYAGER_APPSTORE_API_ISSUER_ID"
    exit 1
  fi

  if [ -z "$API_KEY_PATH" ]; then
    API_KEY_PATH="$HOME/.private_keys/AuthKey_${API_KEY_ID}.p8"
  fi

  if [ ! -f "$API_KEY_PATH" ]; then
    log_error "API key file not found: $API_KEY_PATH"
    log_info "Expected AuthKey_${API_KEY_ID}.p8 in ~/.private_keys or set VOYAGER_APPSTORE_API_KEY_PATH"
    exit 1
  fi
}

upload_ipa() {
  local ipa_path="$1"
  log_step "App Store Connect"

  if [ ! -f "$ipa_path" ]; then
    log_error "IPA not found: $ipa_path"
    exit 1
  fi

  check_api_key

  mkdir -p "$HOME/.private_keys"
  if [ "$API_KEY_PATH" != "$HOME/.private_keys/AuthKey_${API_KEY_ID}.p8" ]; then
    log_warn "altool looks in ~/.private_keys by key id; using explicit path by symlink"
    ln -sf "$API_KEY_PATH" "$HOME/.private_keys/AuthKey_${API_KEY_ID}.p8"
  fi

  local action="--upload-app"
  if [ "$VALIDATE_ONLY" = true ]; then
    action="--validate-app"
    log_info "Validating $(basename "$ipa_path")"
  else
    log_info "Uploading $(basename "$ipa_path")"
  fi

  xcrun altool "$action" \
    --type ios \
    -f "$ipa_path" \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$API_ISSUER_ID"

  if [ "$VALIDATE_ONLY" = true ]; then
    log_ok "Validation completed"
  else
    log_ok "Upload completed"
  fi
}

main() {
  printf "\nVoyager App Store Upload\n" >&2

  check_env
  prepare_keychain

  local ipa_path
  if [ -n "$UPLOAD_ONLY_IPA" ]; then
    ipa_path="$UPLOAD_ONLY_IPA"
  else
    prepare_project
    build_ipa
    ipa_path="$BUILT_IPA_PATH"
    if [ -z "$ipa_path" ]; then
      log_error "Build completed without reporting an IPA path"
      exit 1
    fi
  fi

  if [ "$BUILD_ONLY" = true ]; then
    log_step "Done"
    log_ok "Build-only mode; IPA ready at $ipa_path"
    exit 0
  fi

  upload_ipa "$ipa_path"
}

main
