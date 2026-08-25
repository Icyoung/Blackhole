#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

command_name="${1:-doctor}"
if [ "$#" -gt 0 ]; then
  shift
fi

require_flutter_tvos() {
  if command -v flutter-tvos >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'EOF'
flutter-tvos is not installed or not on PATH.

Install:
  git clone https://github.com/fluttertv/flutter-tvos.git
  export PATH="$PATH:/path/to/flutter-tvos/bin"
  flutter-tvos precache
  flutter-tvos doctor

Then retry this command.
EOF
  exit 127
}

case "$command_name" in
  discover)
    echo "== Xcode devices =="
    xcrun devicectl list devices || true
    echo
    echo "== xcdevice Apple TV entries =="
    xcrun xcdevice list 2>/dev/null | grep -i -E 'apple tv|appletv|tvos|platform.appletv' || true
    echo
    echo "== tvOS runtimes =="
    xcrun simctl list runtimes 2>/dev/null | grep -i -E 'tvos|apple tv|appletv' || true
    echo
    echo "== AirPlay / companion devices on LAN =="
    python3 - <<'PY'
import subprocess
import sys

services = ["_airplay._tcp", "_companion-link._tcp", "_apple-mobdev2._tcp"]
for service in services:
    print(f"-- {service}.local --")
    try:
        proc = subprocess.run(
            ["dns-sd", "-B", service, "local"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=4,
        )
        print(proc.stdout.rstrip())
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        print(output.rstrip())
    except FileNotFoundError:
        print("dns-sd not found", file=sys.stderr)
PY
    ;;
  doctor)
    require_flutter_tvos
    exec flutter-tvos doctor "$@"
    ;;
  devices)
    require_flutter_tvos
    exec flutter-tvos devices "$@"
    ;;
  run)
    require_flutter_tvos
    exec flutter-tvos run \
      --dart-define=BH_TARGET_TVOS=true \
      "$@"
    ;;
  build)
    require_flutter_tvos
    exec flutter-tvos build tvos \
      --dart-define=BH_TARGET_TVOS=true \
      "$@"
    ;;
  open)
    exec open tvos/Runner.xcodeproj
    ;;
  *)
    require_flutter_tvos
    exec flutter-tvos "$command_name" "$@"
    ;;
esac
