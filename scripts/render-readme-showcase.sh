#!/bin/zsh
# Documentation-only renderer. No application installation or user config access.
set -eu
cd "${0:A:h:h}"
command -v cwebp >/dev/null || { print -u2 'Install cwebp to encode README assets.'; exit 1; }
mkdir -p .build
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
TASK_OUTPUT="${1:-$PWD/docs/assets/showcase}"
mkdir -p "$TASK_OUTPUT"
TASK_TEMP="$(mktemp -d "$PWD/.build/readme-showcase.XXXXXX")"
trap 'rm -rf -- "$TASK_TEMP"' EXIT
sips -s format png docs/assets/showcase/woodland.webp --out "$TASK_TEMP/wallpaper.png" >/dev/null
TASK_SOURCES=(Sources/*.swift)
TASK_SOURCES=("${TASK_SOURCES[@]:#Sources/AppMain.swift}")
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_SOURCES[@]}" \
    scripts/ReadmeShowcase.swift -o .build/readme-showcase \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement \
    -framework UniformTypeIdentifiers -framework ApplicationServices -framework ScreenCaptureKit \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/readme-showcase "$TASK_TEMP/wallpaper.png" "$TASK_TEMP/captures"
for TASK_CAPTURE in "$TASK_TEMP"/captures/*.png; do
    cwebp -quiet -q 90 -m 6 -sharp_yuv "$TASK_CAPTURE" -o "$TASK_OUTPUT/${TASK_CAPTURE:t:r}.webp"
done
print -r -- "Native product showcases: $TASK_OUTPUT"
