#!/bin/zsh
# Kitzi for iOS: build an ad-hoc IPA and install it wirelessly over a throwaway
# Cloudflare tunnel (no permanent server) — same flow as the Luli (Reddit) app.
#
#   ./ota.zsh            # serve the existing ~/Downloads/Kitzi.ipa
#   ./ota.zsh --build    # archive + export a fresh ad-hoc IPA first, then serve
#   ./ota.zsh --build-only   # just build the IPA into ~/Downloads
#
# Open the printed link in SAFARI on the iPhone. Ctrl-C stops the tunnel + server.
# Requirements: Xcode signed in to the Kenes team (57L2ULXB7Z) with the device
# registered, `xcodegen` and `cloudflared` (brew install xcodegen cloudflared).

set -e

PROJECT="$(cd "$(dirname "$0")" && pwd)"
IPA_SRC="$HOME/Downloads/Kitzi.ipa"
SERVE="$HOME/Downloads/kitzi-ota"
PORT=8789
BUNDLE_ID="com.bennybar.kitzi"
TITLE="Kitzi"
VERSION=$(grep -m1 'MARKETING_VERSION:' "$PROJECT/project.yml" | sed -E 's/.*"([0-9.]+)".*/\1/')

build() {
  echo "==> building ad-hoc IPA (v$VERSION)"
  ( cd "$PROJECT" && xcodegen generate >/dev/null )
  local ARCHIVE="$PROJECT/build/Kitzi.xcarchive"
  rm -rf "$PROJECT/build"
  xcodebuild -project "$PROJECT/Kitzi.xcodeproj" -scheme Kitzi -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet archive
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$PROJECT/ExportOptions.plist" \
    -exportPath "$PROJECT/build/ipa" -allowProvisioningUpdates -quiet
  cp "$PROJECT"/build/ipa/*.ipa "$IPA_SRC"
  echo "==> $IPA_SRC"
}

if [[ "$1" == "--build" || "$1" == "--build-only" || ! -f "$IPA_SRC" ]]; then build; fi
[[ "$1" == "--build-only" ]] && exit 0
[[ -f "$IPA_SRC" ]] || { echo "✗ no IPA at $IPA_SRC — run ./ota.zsh --build" >&2; exit 1; }
command -v cloudflared >/dev/null || { echo "✗ cloudflared missing: brew install cloudflared" >&2; exit 1; }

rm -rf "$SERVE"; mkdir -p "$SERVE"
cp "$IPA_SRC" "$SERVE/app.ipa"

# Static server with the content types iOS OTA needs.
python3 - "$SERVE" "$PORT" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, os
serve_dir, port = sys.argv[1], int(sys.argv[2])
os.chdir(serve_dir)
class H(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
        '.ipa': 'application/octet-stream', '.plist': 'text/xml', '.html': 'text/html'}
socketserver.TCPServer(("127.0.0.1", port), H).serve_forever()
PY
SERVER_PID=$!

LOG=$(mktemp)
cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate >"$LOG" 2>&1 &
TUNNEL_PID=$!
cleanup() { kill $SERVER_PID $TUNNEL_PID 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "==> bringing up tunnel…"
BASE=""
for i in {1..40}; do
  BASE=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1 || true)
  [[ -n "$BASE" ]] && break
  sleep 1
done
[[ -n "$BASE" ]] || { echo "✗ tunnel didn't come up:" >&2; cat "$LOG" >&2; exit 1; }

cat > "$SERVE/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>$BASE/app.ipa</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>$BUNDLE_ID</string>
    <key>bundle-version</key><string>$VERSION</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>$TITLE</string>
  </dict>
</dict></array></dict></plist>
PLIST

cat > "$SERVE/install.html" <<HTML
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install $TITLE</title></head>
<body style="font-family:-apple-system;text-align:center;padding:60px 24px">
<h2>$TITLE</h2><p>v$VERSION</p>
<p><a style="display:inline-block;background:#5965C8;color:#fff;padding:16px 40px;border-radius:14px;text-decoration:none;font-size:20px"
 href="itms-services://?action=download-manifest&amp;url=$BASE/manifest.plist">Install</a></p>
<p style="color:#888;font-size:14px">Open this page in Safari.</p>
</body></html>
HTML

echo ""
echo "✓ OTA ready. On the iPhone, open this in SAFARI:"
echo ""
echo "    $BASE/install.html"
echo ""
echo "Leave this running; Ctrl-C when done."
wait $TUNNEL_PID
