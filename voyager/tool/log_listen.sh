#!/usr/bin/env bash
# log_listen.sh — Receive Voyager remote logs over UDP port 9526.
#
# Usage:
#   ./voyager/tool/log_listen.sh            # plain output
#   ./voyager/tool/log_listen.sh | tee /tmp/voyager.log   # also save to file
#
# The Voyager iOS app broadcasts all debugPrint output as UDP datagrams
# to 255.255.255.255:9526 when RemoteLogService is active.

PORT=9526

echo "=== Voyager Remote Log Listener (UDP :$PORT) ==="
echo "Waiting for logs from iPhone..."
echo ""

# Use socat if available (better line buffering), fall back to nc.
if command -v socat &>/dev/null; then
  exec socat -u UDP-RECV:$PORT -
else
  exec nc -lu "$PORT"
fi
