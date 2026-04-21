#!/usr/bin/env bash
# Test 10: status should use launchd PID when the lock file is missing
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT_DIR/watchclaw"
TMP_DIR="$(mktemp -d)"
FAKE_HOME="$TMP_DIR/home"
STUB_DIR="$TMP_DIR/stubs"
CONF_DIR="$FAKE_HOME/.config/watchclaw"
LAUNCHAGENT_DIR="$FAKE_HOME/Library/LaunchAgents"
CONF_FILE="$CONF_DIR/watchclaw-launchd.conf"

cleanup() {
  if [[ -n "${SLEEP_PID:-}" ]] && kill -0 "$SLEEP_PID" 2>/dev/null; then
    kill "$SLEEP_PID" 2>/dev/null || true
    sleep 1
    kill -9 "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$CONF_DIR" "$LAUNCHAGENT_DIR" "$STUB_DIR"

cat > "$CONF_FILE" <<EOF
GATEWAY_PORT=19998
GATEWAY_CONFIG_DIR="$TMP_DIR/gateway"
LOG_FILE="$TMP_DIR/watchclaw.log"
MAX_RETRIES=3
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

if [[ "${1:-}" != "print" ]]; then
  echo "unexpected $*" >&2
  exit 1
fi

if [[ "${2:-}" != "gui/501/com.watchclaw.launchd" ]]; then
  exit 1
fi

cat <<OUT
gui/501/com.watchclaw.launchd = {
    state = running
    pid = ${WATCHCLAW_TEST_PID}
}
OUT
EOF

chmod +x "$STUB_DIR/uname" "$STUB_DIR/id" "$STUB_DIR/launchctl"

sleep 300 &
SLEEP_PID=$!

OUTPUT=$(
  PATH="$STUB_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  WATCHCLAW_LAUNCHAGENT_DIR="$LAUNCHAGENT_DIR" \
  WATCHCLAW_TEST_PID="$SLEEP_PID" \
    "$CLI" --config "$CONF_FILE" status
)

if grep -q "State:          STOPPED" <<<"$OUTPUT"; then
  echo "Expected status to use launchd PID instead of STOPPED"
  echo "$OUTPUT"
  exit 1
fi

if ! grep -q "PID:            $SLEEP_PID" <<<"$OUTPUT"; then
  echo "Expected launchd PID in status output"
  echo "$OUTPUT"
  exit 1
fi

if ! grep -q "Supervisor:     launchd (com.watchclaw.launchd)" <<<"$OUTPUT"; then
  echo "Expected launchd supervisor in status output"
  echo "$OUTPUT"
  exit 1
fi

echo "PASS: status falls back to launchd PID"
