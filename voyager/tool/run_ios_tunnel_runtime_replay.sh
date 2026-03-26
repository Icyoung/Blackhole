#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN=$(mktemp /tmp/ios_tunnel_runtime_replay.XXXXXX)
trap 'rm -f "$BIN"' EXIT

swiftc \
  "$ROOT/ios/VoyagerTunnel/TunnelConfig.swift" \
  "$ROOT/ios/VoyagerTunnel/DirectCandidatePlanner.swift" \
  "$ROOT/ios/VoyagerTunnel/DirectDatapathCoordinator.swift" \
  "$ROOT/ios/VoyagerTunnel/TunnelRuntimeCoordinator.swift" \
  "$ROOT/tool/ios_tunnel_runtime_replay.swift" \
  -o "$BIN"

"$BIN"
