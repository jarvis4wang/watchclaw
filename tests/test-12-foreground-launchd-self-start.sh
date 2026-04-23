#!/usr/bin/env bash
# Test 12: launchd foreground invocation should not treat itself as already running
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
APP_DIR="$TMP_DIR/app"
FAKE_HOME="$TMP_DIR/home"
STUB_DIR="$TMP_DIR/stubs"
CONF_DIR="$FAKE_HOME/.config/watchclaw"
LAUNCHAGENT_DIR="$FAKE_HOME/Library/LaunchAgents"
CONF_FILE="$CONF_DIR/watchclaw-jarvis.conf"
MARKER_FILE="$TMP_DIR/watchclaw-sh-ran"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$APP_DIR" "$CONF_DIR" "$LAUNCHAGENT_DIR" "$STUB_DIR"
cp "$ROOT_DIR/watchclaw" "$APP_DIR/watchclaw"
chmod +x "$APP_DIR/watchclaw"

cat > "$APP_DIR/watchclaw.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" > "$WATCHCLAW_TEST_MARKER"
EOF
chmod +x "$APP_DIR/watchclaw.sh"

cat > "$CONF_FILE" <<EOF
GATEWAY_PORT=19996
GATEWAY_CONFIG_DIR="$TMP_DIR/gateway"
LOG_FILE="$TMP_DIR/watchclaw.log"
EOF

cat > "$LAUNCHAGENT_DIR/com.watchclaw.jarvis.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.watchclaw.jarvis</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/watchclaw</string>
    <string>--config</string>
    <string>$CONF_FILE</string>
    <string>start</string>
    <string>--foreground</string>
  </array>
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

if [[ "${1:-}" != "print" || "${2:-}" != "gui/501/com.watchclaw.jarvis" ]]; then
  exit 1
fi

cat <<OUT
gui/501/com.watchclaw.jarvis = {
    state = running
    pid = 42424
}
OUT
EOF

chmod +x "$STUB_DIR/uname" "$STUB_DIR/id" "$STUB_DIR/launchctl"

OUTPUT=$(
  PATH="$STUB_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  XPC_SERVICE_NAME="com.watchclaw.jarvis" \
  WATCHCLAW_LAUNCHAGENT_DIR="$LAUNCHAGENT_DIR" \
  WATCHCLAW_TEST_MARKER="$MARKER_FILE" \
    "$APP_DIR/watchclaw" --config "$CONF_FILE" start --foreground
)

if ! grep -q "Starting watchclaw (foreground) on port 19996" <<<"$OUTPUT"; then
  echo "Expected foreground start message"
  echo "$OUTPUT"
  exit 1
fi

if grep -q "already running" <<<"$OUTPUT"; then
  echo "Did not expect self-detection to report already running"
  echo "$OUTPUT"
  exit 1
fi

if [[ ! -f "$MARKER_FILE" ]]; then
  echo "Expected watchclaw.sh to run"
  exit 1
fi

if ! grep -q "$CONF_FILE" "$MARKER_FILE"; then
  echo "Expected foreground exec to pass the resolved config path"
  cat "$MARKER_FILE"
  exit 1
fi

echo "PASS: launchd foreground start ignores its own service PID"
