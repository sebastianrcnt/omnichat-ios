#!/bin/zsh
# Builds a development-signed Strata.ipa and puts it on an over-the-air install page, served to the tailnet only
# by `tailscale serve` at https://<this Mac>.ts.net/strata/. Open that page on a registered iPhone and tap Install.
#
#   Tools/ota.sh            archive + export + publish
#   Tools/ota.sh --publish  publish the last export again (page only)
set -euo pipefail

REPO=${0:A:h:h}
OUT=${STRATA_OTA_DIR:-$HOME/strata-ota}
WORK=${STRATA_OTA_WORK:-$HOME/Library/Caches/strata-ota-build}
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
command -v tailscale >/dev/null && TS=tailscale
HOST=$($TS status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
BASE="https://$HOST/strata"
BUNDLE=cc.coolservices.strata
PORT=${STRATA_OTA_PORT:-18780}

mkdir -p "$OUT" "$WORK"

if [[ ${1:-} != --publish ]]; then
  cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>CYYK3A72BM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
EOF
  rm -rf "$WORK/Strata.xcarchive" "$WORK/export"
  # Debug, like the builds installed over USB: same debug hooks and developer settings.
  xcodebuild -project "$REPO/Strata.xcodeproj" -scheme Strata -configuration Debug -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates -derivedDataPath "$WORK/dd" -archivePath "$WORK/Strata.xcarchive" archive \
    | grep -a "ARCHIVE SUCCEEDED\|ARCHIVE FAILED\|error: [^t]" || true
  [[ -d "$WORK/Strata.xcarchive" ]] || { echo "archive failed" >&2; exit 1; }
  xcodebuild -exportArchive -archivePath "$WORK/Strata.xcarchive" -exportPath "$WORK/export" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates \
    | grep -a "EXPORT SUCCEEDED\|EXPORT FAILED\|error: [^t]" || true
  [[ -f "$WORK/export/Strata.ipa" ]] || { echo "export failed" >&2; exit 1; }
  cp "$WORK/export/Strata.ipa" "$OUT/Strata.ipa"
  git -C "$REPO" log -1 --format='%h %s' > "$OUT/commit.txt"
fi

[[ -f "$OUT/Strata.ipa" ]] || { echo "no Strata.ipa yet; run without --publish" >&2; exit 1; }
STAMP=$(date -r "$OUT/Strata.ipa" +%s)
BUILT=$(date -r "$OUT/Strata.ipa" '+%Y-%m-%d %H:%M')
COMMIT=$(cat "$OUT/commit.txt" 2>/dev/null || echo "?")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$WORK/Strata.xcarchive/Products/Applications/Strata.app/Info.plist" 2>/dev/null || echo 1.0)

cat > "$OUT/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>$BASE/Strata.ipa?v=$STAMP</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>$BUNDLE</string>
    <key>bundle-version</key><string>$VERSION</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>Strata</string>
  </dict>
</dict></array></dict></plist>
EOF

MANIFEST=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$BASE/manifest.plist?v=$STAMP")
COMMIT_HTML=$(python3 -c 'import html,sys; print(html.escape(sys.argv[1]))' "$COMMIT")
cat > "$OUT/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Strata build</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 17px -apple-system, system-ui, sans-serif; margin: 0; padding: 32px 16px; text-align: center; }
  a.install { display: inline-block; margin: 24px 0; padding: 14px 32px; border-radius: 14px; background: #0a84ff;
              color: #fff; font-weight: 600; text-decoration: none; }
  p { color: #888; margin: 6px 0; }
</style></head>
<body>
  <h1>Strata</h1>
  <p>$COMMIT_HTML</p>
  <p>Built $BUILT</p>
  <a class="install" href="itms-services://?action=download-manifest&amp;url=$MANIFEST">Install</a>
</body></html>
EOF

# The App Store Tailscale can't serve a folder (sandbox), so a loopback-only file server holds it and Tailscale
# proxies to that, tailnet only (serve, not funnel). Both steps are idempotent.
if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  nohup python3 -I -c '
import functools, http.server, sys
H = http.server.SimpleHTTPRequestHandler
H.extensions_map.update({".plist": "text/xml", ".ipa": "application/octet-stream"})
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()
' $PORT "$OUT" >/dev/null 2>&1 &
  sleep 1
fi
$TS serve --bg --https=443 --set-path /strata http://127.0.0.1:$PORT >/dev/null
echo "$BASE/"
