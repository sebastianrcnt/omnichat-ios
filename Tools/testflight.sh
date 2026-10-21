#!/bin/zsh
# Archives a Release build named OpenChat and uploads it to App Store Connect for TestFlight, signed and uploaded with
# the Apple account Xcode is signed in to. The build number is the current time, so every upload is new.
#
#   Tools/testflight.sh           archive + upload
#   Tools/testflight.sh --export  archive + a local .ipa only (no upload)
set -euo pipefail

REPO=${0:A:h:h}
WORK=${STRATA_TF_WORK:-$HOME/Library/Caches/strata-testflight}
BUILD=$(date +%Y%m%d%H%M)
DESTINATION=upload
[[ ${1:-} == --export ]] && DESTINATION=export

mkdir -p "$WORK"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>CYYK3A72BM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

rm -rf "$WORK/OpenChat.xcarchive" "$WORK/export"
xcodebuild -project "$REPO/Strata.xcodeproj" -scheme Strata -configuration Release -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath "$WORK/dd" -archivePath "$WORK/OpenChat.xcarchive" archive \
  INFOPLIST_KEY_CFBundleDisplayName=OpenChat CURRENT_PROJECT_VERSION=$BUILD \
  | grep -a "ARCHIVE SUCCEEDED\|ARCHIVE FAILED\|error: [^t]" || true
[[ -d "$WORK/OpenChat.xcarchive" ]] || { echo "archive failed" >&2; exit 1; }

# Homebrew rsync on PATH breaks the IPA copy step ("Copy failed"): export with the system tools.
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$WORK/OpenChat.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates 2>&1 \
  | grep -av "IDEDistributionLogging\|^\s*$" | tail -25
echo "build $BUILD ($(git -C "$REPO" log -1 --format=%h))"
