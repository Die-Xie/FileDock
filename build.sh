#!/bin/zsh
set -eu
cd "${0:A:h}"
./sign.sh --check
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
TASK_ARCH="$(uname -m)"
TASK_APP="build/FileDock.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" .build
TASK_ARCHS=("$TASK_ARCH")
if [[ "${1:-}" == "--universal" ]]; then TASK_ARCHS=(arm64 x86_64); fi
for TASK_TARGET in "${TASK_ARCHS[@]}"; do
    swiftc -swift-version 5 -O -target "$TASK_TARGET-apple-macos13.0" \
        -module-cache-path .build/module-cache Sources/*.swift \
        -o ".build/FileDock-$TASK_TARGET" \
        -framework AppKit -framework SwiftUI -framework Combine \
        -framework Carbon -framework Quartz -framework QuickLookThumbnailing -framework ImageIO \
        -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
        -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done
if (( ${#TASK_ARCHS[@]} > 1 )); then
    lipo -create .build/FileDock-arm64 .build/FileDock-x86_64 -output "$TASK_APP/Contents/MacOS/FileDock"
else
    cp ".build/FileDock-$TASK_ARCH" "$TASK_APP/Contents/MacOS/FileDock"
fi
mkdir -p "$TASK_APP/Contents/Frameworks"
ditto "$TASK_SPARKLE/Sparkle.framework" "$TASK_APP/Contents/Frameworks/Sparkle.framework"
./scripts/sign-sparkle.sh "$TASK_APP/Contents/Frameworks/Sparkle.framework"
cp "$TASK_SPARKLE/LICENSE" "$TASK_APP/Contents/Resources/Sparkle-LICENSE"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp LICENSE NOTICE "$TASK_APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$TASK_APP/Contents/Resources/AppIcon.icns"
fi
for TASK_LOCALIZATION in Resources/*.lproj; do
    ditto "$TASK_LOCALIZATION" "$TASK_APP/Contents/Resources/${TASK_LOCALIZATION:t}"
done
./sign.sh "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
print -r -- "$PWD/$TASK_APP"
