#!/usr/bin/env bash
# Test 11: macOS background start should use launchd
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT_DIR/watchclaw"
TMP_DIR="$(mktemp -d)"
FAKE_HOME="$TMP_DIR/home"
STUB_DIR="$TMP_DIR/stubs"
CONF_DIR="$FAKE_HOME/.config/watchclaw"
LAUNCHAGENT_DIR="$FAKE_HOME/Library/LaunchAgents"
CONF_FILE="$CONF_DIR/watchclaw-niuniu.conf"
LAUNCHCTL_LOG="$TMP_DIR/launchctl.log"
STATE_FILE="$TMP_DIR/launchctl.state"
PLIST_FILE="$LAUNCHAGENT_DIR/com.watchclaw.niuniu.plist"

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
GATEWAY_PORT=19997
GATEWAY_CONFIG_DIR="$TMP_DIR/gateway"
LOG_FILE="$TMP_DIR/watchclaw.log"
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
  enable)
    echo "enable ${2:-}" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    exit 0
    ;;
  bootout)
    echo "bootout $*" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    rm -f "$WATCHCLAW_TEST_STATE_FILE"
    exit 0
    ;;
  bootstrap)
    echo "bootstrap ${2:-} ${3:-}" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    : > "$WATCHCLAW_TEST_STATE_FILE"
    exit 0
    ;;
  kickstart)
    echo "kickstart ${2:-}" >> "$WATCHCLAW_TEST_LAUNCHCTL_LOG"
    exit 0
    ;;
  print)
    if [[ "${2:-}" == "gui/501/com.watchclaw.niuniu" && -f "$WATCHCLAW_TEST_STATE_FILE" ]]; then
      cat <<OUT
gui/501/com.watchclaw.niuniu = {
    state = running
    pid = ${WATCHCLAW_TEST_PID}
}
OUT
      exit 0
    fi
    exit 1
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

OUTPUT=$(
  PATH="$STUB_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  WATCHCLAW_LAUNCHAGENT_DIR="$LAUNCHAGENT_DIR" \
  WATCHCLAW_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
  WATCHCLAW_TEST_STATE_FILE="$STATE_FILE" \
  WATCHCLAW_TEST_PID="$SLEEP_PID" \
    "$CLI" --config "$CONF_FILE" start
)

if ! grep -q "Starting watchclaw with launchd on port 19997" <<<"$OUTPUT"; then
  echo "Expected launchd start message"
  echo "$OUTPUT"
  exit 1
fi

if ! grep -q "Watchclaw running (launchd: com.watchclaw.niuniu, PID $SLEEP_PID)" <<<"$OUTPUT"; then
  echo "Expected launchd success message"
  echo "$OUTPUT"
  exit 1
fi

if [[ ! -f "$PLIST_FILE" ]]; then
  echo "Expected launchd plist to be created"
  exit 1
fi

if ! grep -q "<string>$CONF_FILE</string>" "$PLIST_FILE"; then
  echo "Expected config path in launchd plist"
  cat "$PLIST_FILE"
  exit 1
fi

if ! grep -q "<string>--foreground</string>" "$PLIST_FILE"; then
  echo "Expected launchd plist to run watchclaw in foreground"
  cat "$PLIST_FILE"
  exit 1
fi

if ! grep -q "<key>WatchclawManaged</key>" "$PLIST_FILE"; then
  echo "Expected managed marker in launchd plist"
  cat "$PLIST_FILE"
  exit 1
fi

if ! grep -q "enable gui/501/com.watchclaw.niuniu" "$LAUNCHCTL_LOG"; then
  echo "Expected launchctl enable call"
  cat "$LAUNCHCTL_LOG" 2>/dev/null || true
  exit 1
fi

if ! grep -q "bootstrap gui/501 $PLIST_FILE" "$LAUNCHCTL_LOG"; then
  echo "Expected launchctl bootstrap call"
  cat "$LAUNCHCTL_LOG" 2>/dev/null || true
  exit 1
fi

echo "PASS: macOS start uses launchd"
