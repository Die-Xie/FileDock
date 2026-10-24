#!/bin/zsh
# Manual equivalent of Xcode Embed & Sign: seal nested executables inside-out.
set -eu
cd "${0:A:h:h}"
TASK_FRAMEWORK="${1:?Sparkle.framework}"
[[ "$TASK_FRAMEWORK" == */Contents/Frameworks/Sparkle.framework && -d "$TASK_FRAMEWORK/Versions/B" ]] || exit 1
TASK_CONFIG="$HOME/Library/Application Support/FileDock/Signing/identity.plist"
TASK_CERT="$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$TASK_CONFIG")"
TASK_KEYCHAIN="$(/usr/libexec/PlistBuddy -c 'Print :keychainPath' "$TASK_CONFIG")"
[[ "$TASK_CERT" =~ '^[0-9A-F]{40}$' ]] || exit 1
TASK_BASE="$TASK_FRAMEWORK/Versions/B"
for TASK_PART in Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
    TASK_ID="org.sparkle-project.Sparkle.${TASK_PART:t:r}"
    /usr/bin/codesign --force --sign "$TASK_CERT" --keychain "$TASK_KEYCHAIN" --timestamp=none \
        --preserve-metadata=entitlements,flags --identifier "$TASK_ID" "$TASK_BASE/$TASK_PART"
done
/usr/bin/codesign --force --sign "$TASK_CERT" --keychain "$TASK_KEYCHAIN" --timestamp=none \
    --identifier org.sparkle-project.Sparkle "$TASK_FRAMEWORK"
/usr/bin/codesign --verify --deep --strict --all-architectures "$TASK_FRAMEWORK"
