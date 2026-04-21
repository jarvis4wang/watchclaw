#!/usr/bin/env bash
# Test 09: macOS launchd-managed stop should boot out the service first
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT_DIR/watchclaw"
TMP_DIR="$(mktemp -d)"
FAKE_HOME="$TMP_DIR/home"
STUB_DIR="$TMP_DIR/stubs"
CONF_DIR="$FAKE_HOME/.config/watchclaw"
LAUNCHAGENT_DIR="$FAKE_HOME/Library/LaunchAgents"
CONF_FILE="$CONF_DIR/watchclaw-launchd.conf"
LOCK_FILE="/tmp/watchclaw-19999.pid"
LAUNCHCTL_LOG="$TMP_DIR/launchctl.log"

cleanup() {
  if [[ -n "${SLEEP_PID:-}" ]] && kill -0 "$SLEEP_PID" 2>/dev/null; then
    kill "$SLEEP_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -f "$LOCK_FILE"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$CONF_DIR" "$LAUNCHAGENT_DIR" "$STUB_DIR"

cat > "$CONF_FILE" <<EOF
GATEWAY_PORT=19999
GATEWAY_CONFIG_DIR="$TMP_DIR/gateway"
LOG_FILE="$TMP_DIR/watchclaw.log"
EOF

cat > "$LAUNCHAGENT_DIR/com.watchclaw.launchd.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.watchclaw.launchd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/test/.local/bin/watchclaw</string>
    <string>--config</string>
    <string>$CONF_FILE</string>
    <string>start</string>
    <string>--foreground</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

cat > "$STUB_DIR/uname" <<'EOF'
#!/usr/bin/env bash
echo "Darwin"
EOF

cat > "$STUB_DIR/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo "501"
  exit 0
fi
echo "unsupported" >&2
exit 1
EOF

cat > "$STUB_DIR/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  print)
    if [[ "${2:-}" == "gui/501/com.watchclaw.launchd" ]]; then
      exit 0
    fi
    exit 1
    ;;
  bootout)
    echo "bootout ${2:-}" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    exit 0
    ;;
  disable)
    echo "disable ${2:-}" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    exit 0
    ;;
  *)
    echo "unexpected $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$STUB_DIR/uname" "$STUB_DIR/id" "$STUB_DIR/launchctl"

sleep 300 &
SLEEP_PID=$!
echo "$SLEEP_PID" > "$LOCK_FILE"

OUTPUT=$(
  PATH="$STUB_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  WATCHCLAW_LAUNCHAGENT_DIR="$LAUNCHAGENT_DIR" \
  WATCHCLAW_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    "$CLI" --config "$CONF_FILE" stop
)

if ! grep -q "Stopping watchclaw launchd service (com.watchclaw.launchd)" <<<"$OUTPUT"; then
  echo "Expected launchd stop message"
  echo "$OUTPUT"
  exit 1
fi

if ! grep -q "bootout gui/501/com.watchclaw.launchd" "$LAUNCHCTL_LOG"; then
  echo "Expected launchctl bootout call"
  cat "$LAUNCHCTL_LOG" 2>/dev/null || true
  exit 1
fi

if ! grep -q "disable gui/501/com.watchclaw.launchd" "$LAUNCHCTL_LOG"; then
  echo "Expected launchctl disable call"
  cat "$LAUNCHCTL_LOG" 2>/dev/null || true
  exit 1
fi

if kill -0 "$SLEEP_PID" 2>/dev/null; then
  echo "Expected watchclaw PID to be stopped"
  exit 1
fi

if [[ -e "$LOCK_FILE" ]]; then
  echo "Expected lock file to be removed"
  exit 1
fi

echo "PASS: launchd-managed stop boots out the service"
