#!/bin/zsh
# Authenticate the public production feed through real Sparkle, without installing.
set -eu
umask 077
cd "${0:A:h}"
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
TASK_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/FileDock-live-update.XXXXXX")"
TASK_TEST_ID="local.diexie.filedock.live-update-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
    uv run --no-project python - "$TASK_ROOT" "$TASK_TEST_ID" <<'PY'
import pathlib, shutil, sys
root, identifier = sys.argv[1:]
if pathlib.Path(root).name.startswith('FileDock-live-update.'):
    shutil.rmtree(root, ignore_errors=True)
if identifier.startswith('local.diexie.filedock.live-update-test.'):
    for folder in ['Library/Caches', 'Library/Preferences']:
        path = pathlib.Path.home()/folder/(identifier + ('.plist' if folder.endswith('Preferences') else ''))
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink(missing_ok=True)
PY
}
trap cleanup EXIT
TASK_APP="$TASK_ROOT/LiveUpdateCheck.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Frameworks"
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache -F "$TASK_SPARKLE" \
    Tests/LiveUpdateCheck.swift -o "$TASK_APP/Contents/MacOS/LiveUpdateCheck" \
    -framework AppKit -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
ditto "$TASK_SPARKLE/Sparkle.framework" "$TASK_APP/Contents/Frameworks/Sparkle.framework"
uv run --no-project python - Resources/Info.plist "$TASK_APP/Contents/Info.plist" "$TASK_TEST_ID" "${1:-current}" <<'PY'
import plistlib, sys
source, target, identifier, mode = sys.argv[1:]
assert mode in ('current', 'older')
with open(source, 'rb') as file: info = plistlib.load(file)
for key in ['CFBundleIconFile', 'CFBundleURLTypes']: info.pop(key, None)
info.update(CFBundleIdentifier=identifier, CFBundleName='FileDock Live Update Test',
            CFBundleDisplayName='FileDock Live Update Test', CFBundleExecutable='LiveUpdateCheck',
            FDLiveExpectUpdate=(mode == 'older'))
if mode == 'older': info.update(CFBundleVersion='0', CFBundleShortVersionString='0.0.0')
with open(target, 'wb') as file: plistlib.dump(info, file)
PY
./scripts/sign-sparkle.sh "$TASK_APP/Contents/Frameworks/Sparkle.framework"
TASK_CERT="$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$HOME/Library/Application Support/FileDock/Signing/identity.plist")"
codesign --force --sign "$TASK_CERT" --timestamp=none --identifier "$TASK_TEST_ID" "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
"$TASK_APP/Contents/MacOS/LiveUpdateCheck"
