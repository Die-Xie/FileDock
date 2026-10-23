#!/bin/zsh
set -eu
cd "${0:A:h}"
./setup-signing.sh --check
TASK_SIGN_CONFIG="$HOME/Library/Application Support/FileDock/Signing/identity.plist"
if [[ ! -f "$TASK_SIGN_CONFIG" ]]; then
    print -u2 -- "缺少固定签名身份。请先运行 ./setup-signing.sh；构建不会退回临时签名。"
    exit 1
fi
TASK_CERT_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$TASK_SIGN_CONFIG")"
TASK_KEYCHAIN="$(/usr/libexec/PlistBuddy -c 'Print :keychainPath' "$TASK_SIGN_CONFIG")"
TASK_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :bundleIdentifier' "$TASK_SIGN_CONFIG")"
if [[ ! "$TASK_CERT_SHA1" =~ '^[0-9A-F]{40}$' || "$TASK_IDENTIFIER" != "local.diexie.filedock" || ! -f "$TASK_KEYCHAIN" ]]; then
    print -u2 -- "固定签名配置无效，已停止。请恢复原有签名身份。"
    exit 1
fi
if [[ "${1:-}" == "--check" ]]; then
    exit 0
fi
TASK_SIGN_TARGET="${1:?usage: ./sign.sh app-or-executable}"
TASK_REQUIREMENT="identifier \"$TASK_IDENTIFIER\" and certificate leaf = H\"$TASK_CERT_SHA1\""
/usr/bin/codesign --force --sign "$TASK_CERT_SHA1" --keychain "$TASK_KEYCHAIN" --timestamp=none \
    --identifier "$TASK_IDENTIFIER" --requirements "=designated => $TASK_REQUIREMENT" -- "$TASK_SIGN_TARGET"
/usr/bin/codesign --verify --strict --all-architectures --test-requirement "=$TASK_REQUIREMENT" -- "$TASK_SIGN_TARGET"
