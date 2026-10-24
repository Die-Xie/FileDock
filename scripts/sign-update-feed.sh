#!/bin/zsh
# Called only with a validated signed release ZIP in a private staging folder.
set -eu
cd "${0:A:h:h}"
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
TASK_ARCHIVE="${1:?archive}"
TASK_NOTES="${2:?notes}"
TASK_TAG="${3:?vX.Y.Z}"
TASK_DEST="${4:?output-directory}"
[[ "$TASK_TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
TASK_PUBLIC="$($TASK_SPARKLE/bin/generate_keys --account filedock-diexie -p)"
[[ "$TASK_PUBLIC" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)" ]] || { print -u2 'Missing or incorrect update signing key. Restore the original keychain key.'; exit 1; }
# Do not generate keys here: publishing must never rotate trust accidentally.
mkdir -p "$TASK_DEST"
cp "$TASK_ARCHIVE" "$TASK_DEST/FileDock.zip"
cp "$TASK_NOTES" "$TASK_DEST/FileDock.md"
"$TASK_SPARKLE/bin/generate_appcast" --account filedock-diexie --maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "https://github.com/Die-Xie/FileDock/releases/download/$TASK_TAG/" \
    --link "https://github.com/Die-Xie/FileDock" --embed-release-notes "$TASK_DEST"
swiftc -swift-version 5 -O -module-cache-path .build/module-cache scripts/VerifyUpdate.swift -o .build/verify-update
.build/verify-update "$TASK_PUBLIC" "$TASK_DEST/appcast.xml" "$TASK_DEST/FileDock.zip" "$TASK_TAG"
