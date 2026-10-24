#!/bin/zsh
# Official, pinned dependency; never execute an unverified downloaded tool.
set -eu
cd "${0:A:h:h}"
TASK_VERSION=2.10.0
TASK_SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
TASK_CACHE="$PWD/.build/dependencies"
TASK_ARCHIVE="$TASK_CACHE/Sparkle-$TASK_VERSION.tar.xz"
TASK_DEST="$TASK_CACHE/Sparkle-$TASK_VERSION"
mkdir -p "$TASK_CACHE"
if [[ ! -f "$TASK_ARCHIVE" ]]; then
    curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$TASK_VERSION/Sparkle-$TASK_VERSION.tar.xz" -o "$TASK_ARCHIVE.partial"
    mv "$TASK_ARCHIVE.partial" "$TASK_ARCHIVE"
fi
[[ "$(shasum -a 256 "$TASK_ARCHIVE" | cut -d ' ' -f 1)" == "$TASK_SHA" ]] || { print -u2 'Sparkle archive checksum mismatch.'; exit 1; }
# Re-extract verified bytes before running build/publishing tools. Validating
# only the archive would not detect a changed executable in an old cache.
TASK_FRESH="$(mktemp -d "$TASK_CACHE/.sparkle-verified.XXXXXX")"
tar -xf "$TASK_ARCHIVE" -C "$TASK_FRESH"
codesign --verify --deep --strict "$TASK_FRESH/Sparkle.framework"
if [[ -e "$TASK_DEST" ]]; then
    TASK_OLD="$(mktemp -d "$TASK_CACHE/.sparkle-old.XXXXXX")"
    mv "$TASK_DEST" "$TASK_OLD/distribution"
    mv "$TASK_FRESH" "$TASK_DEST"
    uv run --no-project python -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$TASK_OLD"
else
    mv "$TASK_FRESH" "$TASK_DEST"
fi
print -r -- "$TASK_DEST"
