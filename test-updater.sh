#!/bin/zsh
# Exercise Sparkle's actual download -> signature -> install -> relaunch pipeline
# against a disposable app identity/key and loopback feed, never /Applications.
set -eu
umask 077
cd "${0:A:h}"
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
TASK_TEST_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/FileDock-updater-integration.XXXXXX")"
TASK_SERVER_PID=""
TASK_APP_PID=""
TASK_TEST_ID=""
cleanup() {
    if [[ -n "$TASK_SERVER_PID" ]]; then kill "$TASK_SERVER_PID" 2>/dev/null || true; fi
    if [[ -n "$TASK_APP_PID" ]] && kill -0 "$TASK_APP_PID" 2>/dev/null; then
        TASK_COMMAND="$(ps -p "$TASK_APP_PID" -o comm=)"
        [[ "$TASK_COMMAND" == "$TASK_TEST_ROOT/installed/UpdateFixture.app/Contents/MacOS/UpdateFixture" ]] && kill "$TASK_APP_PID" 2>/dev/null || true
    fi
    if [[ -d "$TASK_TEST_ROOT" && "$TASK_TEST_ROOT" == "${TMPDIR:-/private/tmp}/FileDock-updater-integration."* ]]; then
        uv run --no-project python - "$TASK_TEST_ROOT" "$TASK_TEST_ID" <<'PY'
import os,pathlib,plistlib,shutil,signal,subprocess,sys
root,identifier=sys.argv[1:]
for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
    pid,_,command=line.strip().partition(' ')
    if command.strip().startswith(root+'/'):
        try: os.kill(int(pid),signal.SIGTERM)
        except ProcessLookupError: pass
if identifier.startswith('local.diexie.filedock.updater-test.'):
    cache=pathlib.Path.home()/'Library/Caches'/identifier
    if cache.is_dir(): shutil.rmtree(cache)
    for app in (pathlib.Path.home()/'.Trash').glob('UpdateFixture*.app'):
        try:
            with (app/'Contents/Info.plist').open('rb') as file: info=plistlib.load(file)
            if info.get('CFBundleIdentifier')==identifier: shutil.rmtree(app)
        except OSError: pass
shutil.rmtree(root)
PY
    fi
}
trap cleanup EXIT
swiftc -swift-version 5 -module-cache-path .build/module-cache Tests/UpdateFixtureKey.swift -o .build/update-fixture-key
TASK_PUBLIC="$(.build/update-fixture-key "$TASK_TEST_ROOT/test-only.key")"
uv run --no-project python Tests/UpdateServer.py "$TASK_TEST_ROOT" > "$TASK_TEST_ROOT/server.log" 2>&1 &
TASK_SERVER_PID=$!
for TASK_ATTEMPT in {1..100}; do [[ -f "$TASK_TEST_ROOT/port" ]] && break; sleep 0.1; done
TASK_PORT="$(cat "$TASK_TEST_ROOT/port")"
TASK_TEST_ID="local.diexie.filedock.updater-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache -F "$TASK_SPARKLE" \
    Tests/UpdaterFixture.swift -o .build/UpdaterFixture -framework AppKit -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
TASK_SIGN_CONFIG="$HOME/Library/Application Support/FileDock/Signing/identity.plist"
TASK_CERT="$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$TASK_SIGN_CONFIG")"
for TASK_VERSION in 1 2; do
    TASK_APP="$TASK_TEST_ROOT/version$TASK_VERSION/UpdateFixture.app"
    mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Frameworks"
    cp .build/UpdaterFixture "$TASK_APP/Contents/MacOS/UpdateFixture"
    ditto "$TASK_SPARKLE/Sparkle.framework" "$TASK_APP/Contents/Frameworks/Sparkle.framework"
    uv run --no-project python - "$TASK_APP/Contents/Info.plist" "$TASK_VERSION" "$TASK_TEST_ID" "$TASK_PUBLIC" "$TASK_PORT" "$TASK_TEST_ROOT/result" <<'PY'
import plistlib,sys
file,version,identifier,key,port,result=sys.argv[1:]
info=dict(CFBundleIdentifier=identifier,CFBundleName='FileDock Updater Test',CFBundleExecutable='UpdateFixture',CFBundlePackageType='APPL',CFBundleShortVersionString=version+'.0',CFBundleVersion=version,LSMinimumSystemVersion='13.0',LSUIElement=True,SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml',SUPublicEDKey=key,SUEnableAutomaticChecks=False,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0,FDTestResultPath=result,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
with open(file,'wb') as out:plistlib.dump(info,out)
PY
    ./scripts/sign-sparkle.sh "$TASK_APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$TASK_CERT" --timestamp=none --identifier "$TASK_TEST_ID" "$TASK_APP"
    codesign --verify --deep --strict "$TASK_APP"
done
TASK_ZIP="$TASK_TEST_ROOT/UpdateFixture.zip"
ditto -c -k --sequesterRsrc --keepParent "$TASK_TEST_ROOT/version2/UpdateFixture.app" "$TASK_ZIP"
TASK_SIGNATURE="$("$TASK_SPARKLE/bin/sign_update" --ed-key-file "$TASK_TEST_ROOT/test-only.key" -p "$TASK_ZIP")"
uv run --no-project python - "$TASK_TEST_ROOT/appcast.xml" "$TASK_PORT" "$TASK_SIGNATURE" "$TASK_ZIP" <<'PY'
import pathlib,sys,xml.etree.ElementTree as ET
file,port,signature,archive=sys.argv[1:]
ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',ns)
root=ET.Element('rss',version='2.0');channel=ET.SubElement(root,'channel');ET.SubElement(channel,'title').text='Isolated FileDock updater test'
item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='Test version 2'
ET.SubElement(item,'{'+ns+'}version').text='2';ET.SubElement(item,'{'+ns+'}shortVersionString').text='2.0'
ET.SubElement(item,'{'+ns+'}minimumSystemVersion').text='13.0'
ET.SubElement(item,'enclosure',{'url':f'http://127.0.0.1:{port}/UpdateFixture.zip','length':str(pathlib.Path(archive).stat().st_size),'type':'application/octet-stream','{'+ns+'}edSignature':signature})
ET.ElementTree(root).write(file,encoding='utf-8',xml_declaration=True)
PY
"$TASK_SPARKLE/bin/sign_update" --ed-key-file "$TASK_TEST_ROOT/test-only.key" "$TASK_TEST_ROOT/appcast.xml"
"$TASK_SPARKLE/bin/sign_update" --ed-key-file "$TASK_TEST_ROOT/test-only.key" --verify "$TASK_TEST_ROOT/appcast.xml"
mkdir -p "$TASK_TEST_ROOT/installed"
ditto "$TASK_TEST_ROOT/version1/UpdateFixture.app" "$TASK_TEST_ROOT/installed/UpdateFixture.app"
run_fixture() {
    TASK_EXPECTED="$1"
    uv run --no-project python - "$TASK_TEST_ROOT" <<'PYTEST'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
for name in ['result','result.pid']:(root/name).unlink(missing_ok=True)
PYTEST
    open -n "$TASK_TEST_ROOT/installed/UpdateFixture.app" --stdout "$TASK_TEST_ROOT/app.log" --stderr "$TASK_TEST_ROOT/app.log"
    for TASK_ATTEMPT in {1..100}; do [[ -f "$TASK_TEST_ROOT/result.pid" ]] && break; sleep 0.1; done
    TASK_APP_PID="$(cat "$TASK_TEST_ROOT/result.pid")"
    for TASK_ATTEMPT in {1..500}; do [[ -f "$TASK_TEST_ROOT/result" ]] && break; sleep 0.1; done
    if [[ ! -f "$TASK_TEST_ROOT/result" ]]; then cat "$TASK_TEST_ROOT/app.log" "$TASK_TEST_ROOT/server.log"; print -u2 'Updater fixture timed out'; exit 1; fi
    TASK_RESULT="$(cat "$TASK_TEST_ROOT/result")"
    if [[ "$TASK_EXPECTED" == FAIL ]]; then
        [[ "$TASK_RESULT" == FAIL:* ]]
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TASK_TEST_ROOT/installed/UpdateFixture.app/Contents/Info.plist")" == 1 ]]
        print 'PASS: tampered update rejected; installed app preserved'
    else
        [[ "$TASK_RESULT" == 'PASS: signed update installed and relaunched' ]]
        print -r -- "$TASK_RESULT"
    fi
    sleep 0.3
}
cp "$TASK_TEST_ROOT/appcast.xml" "$TASK_TEST_ROOT/trusted-feed"
cp "$TASK_ZIP" "$TASK_TEST_ROOT/trusted-archive"
uv run --no-project python - "$TASK_TEST_ROOT/appcast.xml" <<'PYTEST'
import pathlib,sys
file=pathlib.Path(sys.argv[1]);file.write_bytes(file.read_bytes().replace(b'Test version 2',b'Evil version 2'))
PYTEST
run_fixture FAIL
cp "$TASK_TEST_ROOT/trusted-feed" "$TASK_TEST_ROOT/appcast.xml"
uv run --no-project python - "$TASK_ZIP" <<'PYTEST'
import pathlib,sys
file=pathlib.Path(sys.argv[1]);data=bytearray(file.read_bytes());data[64]^=1;file.write_bytes(data)
PYTEST
run_fixture FAIL
cp "$TASK_TEST_ROOT/trusted-archive" "$TASK_ZIP"
run_fixture PASS
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TASK_TEST_ROOT/installed/UpdateFixture.app/Contents/Info.plist")" == 2 ]]
codesign --verify --deep --strict "$TASK_TEST_ROOT/installed/UpdateFixture.app"
print 'PASS: real Sparkle EdDSA feed/archive verification, replacement and relaunch in an isolated app; production app/settings/key unchanged'
