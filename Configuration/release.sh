#!/bin/zsh
# Builds the committed HEAD, signs it for Sparkle and publishes a GitHub release that
# travisNotch's updater (SUFeedURL = releases/latest/download/appcast.xml) picks up.
#
# Before running: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION (higher than the last
# release) in boringNotch.xcodeproj, commit, and push to travisherpaz/travisNotch.
# The Sparkle private key lives in the login keychain under the account "travisnotch".
set -euo pipefail

REPO=travisherpaz/travisNotch
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
WORK=$(mktemp -d)
trap 'git -C "$ROOT" worktree remove --force "$WORK/src" 2>/dev/null; rm -rf "$WORK"' EXIT

SHA=$(git -C "$ROOT" rev-parse HEAD)
git -C "$ROOT" fetch -q fork travis
[[ $(git -C "$ROOT" rev-parse fork/travis) == "$SHA" ]] || { echo "Push HEAD to fork/travis first." >&2; exit 1; }

git -C "$ROOT" worktree add -q --detach "$WORK/src" "$SHA"
xcodebuild -quiet -project "$WORK/src/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -derivedDataPath "$WORK/build" CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO build

APP="$WORK/build/Build/Products/Release/travisNotch.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
TAG="v$VERSION"
ZIP="$WORK/travisNotch.zip"
(cd "${APP:h}" && ditto -c -k --keepParent travisNotch.app "$ZIP")

SPARKLE_BIN="$WORK/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account travisnotch "$ZIP")  # sparkle:edSignature="…" length="…"

cat > "$WORK/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>travisNotch</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/travisNotch.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

gh release create "$TAG" "$ZIP" "$WORK/appcast.xml" -R "$REPO" --target "$SHA" --title "travisNotch $TAG" \
  --notes-file "$ROOT/Configuration/release-notes.md"
