#!/bin/zsh
# Integration test: uses only temporary command-line executables, never extra .app copies.
set -eu
cd "${0:A:h}"
./sign.sh --check
TASK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/FolderHubSigningTest.XXXXXX")"
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
/usr/bin/clang -x c -o "$TASK_TEST_DIR/first" - <<'C'
int main(void) { return 11; }
C
/usr/bin/clang -x c -o "$TASK_TEST_DIR/update" - <<'C'
int main(void) { return 22; }
C
cp "$TASK_TEST_DIR/update" "$TASK_TEST_DIR/adhoc"
cp "$TASK_TEST_DIR/update" "$TASK_TEST_DIR/wrong-bundle"
./sign.sh "$TASK_TEST_DIR/first"
./sign.sh "$TASK_TEST_DIR/update"
/usr/bin/codesign -d -r- "$TASK_TEST_DIR/first" > "$TASK_TEST_DIR/requirements.txt" 2>/dev/null
TASK_REQUIREMENT="$(sed -n 's/^designated => //p' "$TASK_TEST_DIR/requirements.txt")"
[[ -n "$TASK_REQUIREMENT" && "$TASK_REQUIREMENT" == *'certificate leaf'* && "$TASK_REQUIREMENT" != *cdhash* ]]
TASK_FIRST_HASH="$(shasum -a 256 "$TASK_TEST_DIR/first" | cut -d ' ' -f 1)"
TASK_UPDATE_HASH="$(shasum -a 256 "$TASK_TEST_DIR/update" | cut -d ' ' -f 1)"
[[ "$TASK_FIRST_HASH" != "$TASK_UPDATE_HASH" ]]
/usr/bin/codesign --verify --strict --test-requirement "=$TASK_REQUIREMENT" "$TASK_TEST_DIR/update"
/usr/bin/codesign --force --sign - --identifier local.diexie.folderhub-replica "$TASK_TEST_DIR/adhoc"
if /usr/bin/codesign --verify --test-requirement "=$TASK_REQUIREMENT" "$TASK_TEST_DIR/adhoc" >/dev/null 2>&1; then
    print -u2 -- 'FAIL: ad-hoc signature matched persistent identity'; exit 1
fi
TASK_SIGN_CONFIG="$HOME/Library/Application Support/FolderHubReplica/Signing/identity.plist"
TASK_CERT_SHA1="$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$TASK_SIGN_CONFIG")"
TASK_KEYCHAIN="$(/usr/libexec/PlistBuddy -c 'Print :keychainPath' "$TASK_SIGN_CONFIG")"
/usr/bin/codesign --force --sign "$TASK_CERT_SHA1" --keychain "$TASK_KEYCHAIN" --timestamp=none \
    --identifier local.diexie.other-app "$TASK_TEST_DIR/wrong-bundle"
if /usr/bin/codesign --verify --test-requirement "=$TASK_REQUIREMENT" "$TASK_TEST_DIR/wrong-bundle" >/dev/null 2>&1; then
    print -u2 -- 'FAIL: other bundle matched persistent identity'; exit 1
fi
TASK_WRONG_CERT_REQUIREMENT='identifier "local.diexie.folderhub-replica" and certificate leaf = H"0000000000000000000000000000000000000000"'
if /usr/bin/codesign --verify --test-requirement "=$TASK_WRONG_CERT_REQUIREMENT" "$TASK_TEST_DIR/update" >/dev/null 2>&1; then
    print -u2 -- 'FAIL: wrong certificate requirement accepted'; exit 1
fi
print -- 'PASS: different executable updates satisfy the first build identity; ad-hoc, other bundle and wrong certificate requirements are rejected'
