#!/bin/bash
# Publish the already-tested, locally signed app using only the origin SSH remote.
set -euo pipefail
umask 077

fail() { printf 'Release stopped: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s [--dry-run] /path/FileDock.zip /path/RELEASE_NOTES.md [vX.Y.Z]\n' "$0" >&2; exit 2; }
TASK_DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then TASK_DRY_RUN=1; shift; fi
[[ $# -ge 2 && $# -le 3 ]] || usage
TASK_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$TASK_ROOT"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit all source changes first; the working tree must be clean.'
TASK_HEAD="$(git rev-parse --verify HEAD)"
TASK_ARCHIVE="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
TASK_NOTES="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
[[ -f "$TASK_ARCHIVE" && -f "$TASK_NOTES" ]] || fail 'Archive and release notes must be regular files.'
TASK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TASK_TAG="${3:-v$TASK_VERSION}"
[[ "$TASK_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Use a stable vX.Y.Z tag without leading zeroes.'
[[ "$TASK_TAG" == "v$TASK_VERSION" ]] || fail 'Tag must match Resources/Info.plist.'
TASK_BRANCH="release-assets/$TASK_TAG"
TASK_REMOTE="$(git remote get-url --push --all origin)"
[[ "$TASK_REMOTE" != *$'\n'* && "$TASK_REMOTE" == "$(git remote get-url origin)" ]] || fail 'origin must have one matching fetch/push SSH URL.'
case "$TASK_REMOTE" in
    git@github.com:*|ssh://git@github.com/*) ;;
    *) fail 'origin must use GitHub SSH; this script does not need a local GitHub API token.' ;;
esac
[[ -f .github/workflows/release.yml ]] || fail 'The committed release workflow is missing.'
git cat-file -e "$TASK_HEAD:.github/workflows/release.yml"
if git show-ref --verify --quiet "refs/tags/$TASK_TAG"; then fail "Local tag $TASK_TAG already exists."; fi
TASK_REMOTE_MAIN="$(git ls-remote origin refs/heads/main)"
[[ "$TASK_REMOTE_MAIN" == "$TASK_HEAD"$'\trefs/heads/main' ]] || fail 'Push this clean source commit to origin/main before publishing.'
TASK_REMOTE_REFS="$(git ls-remote origin "refs/tags/$TASK_TAG" "refs/heads/$TASK_BRANCH")"
[[ -z "$TASK_REMOTE_REFS" ]] || fail 'The release tag or artifact branch already exists; inspect it instead of overwriting.'

TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/FileDock-release.XXXXXX")"
trap 'rm -rf -- "$TASK_TEMP"' EXIT
cp "$TASK_ARCHIVE" "$TASK_TEMP/FileDock.zip"
cp "$TASK_NOTES" "$TASK_TEMP/RELEASE_NOTES.md"
printf '%s\n' "$TASK_HEAD" > "$TASK_TEMP/SOURCE_COMMIT"
# Validate without extracting or executing anything from the archive.
python3 - "$TASK_TEMP/FileDock.zip" "$TASK_VERSION" "$TASK_TEMP/RELEASE_NOTES.md" <<'PY'
import pathlib, plistlib, sys, zipfile
archive, version, notes = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
assert 0 < archive.stat().st_size < 95 * 1024 * 1024, 'ZIP must be smaller than 95 MiB for the temporary Git branch'
assert 0 < notes.stat().st_size <= 1024 * 1024, 'Release notes must be nonempty and at most 1 MiB'
notes.read_text(encoding='utf-8')
with zipfile.ZipFile(archive) as package:
    names = package.namelist()
    assert len(names) == len(set(names)), 'Duplicate ZIP entries are not accepted'
    for name in names:
        parts = pathlib.PurePosixPath(name).parts
        assert parts and not name.startswith('/') and '..' not in parts and '\\' not in name, 'Unsafe ZIP path'
        assert parts[0] == 'FileDock.app' or (parts[0] == '__MACOSX' and (len(parts) == 1 or parts[1] in ('FileDock.app', '._FileDock.app'))), 'ZIP must contain only FileDock.app and its resource-fork metadata'
        assert not any(part.endswith(('.pem', '.p12', '.pfx', '.keychain', '.keychain-db')) or part == 'identity.plist' for part in parts), 'Signing material must never be packaged'
    info = plistlib.loads(package.read('FileDock.app/Contents/Info.plist'))
    assert info['CFBundleShortVersionString'] == version, 'ZIP version differs from the committed source version'
    assert info['CFBundleIdentifier'] == 'local.diexie.folderhub-replica', 'The fixed application identity must not change'
    assert info['CFBundleName'] == 'FileDock' and info['CFBundleDisplayName'] == 'FileDock', 'Unexpected application name'
    assert package.testzip() is None, 'ZIP integrity check failed'
PY
unzip -tq "$TASK_TEMP/FileDock.zip"
(cd "$TASK_TEMP" && shasum -a 256 FileDock.zip RELEASE_NOTES.md SOURCE_COMMIT > SHA256SUMS.txt)

# Build an orphan tree with four explicit blobs. The checkout and real index are untouched.
TASK_INDEX="$TASK_TEMP/git-index"
GIT_INDEX_FILE="$TASK_INDEX" git read-tree --empty
for TASK_FILE in FileDock.zip SHA256SUMS.txt RELEASE_NOTES.md SOURCE_COMMIT; do
    TASK_BLOB="$(git hash-object -w -- "$TASK_TEMP/$TASK_FILE")"
    GIT_INDEX_FILE="$TASK_INDEX" git update-index --add --cacheinfo "100644,$TASK_BLOB,$TASK_FILE"
done
TASK_TREE="$(GIT_INDEX_FILE="$TASK_INDEX" git write-tree)"
TASK_COMMIT="$(printf 'chore: stage release assets for %s\n\nSource: %s\n' "$TASK_TAG" "$TASK_HEAD" | git -c commit.gpgSign=false commit-tree "$TASK_TREE")"
printf 'Source: %s\nTag: %s\nArtifact branch: %s\nArtifact commit: %s\n' "$TASK_HEAD" "$TASK_TAG" "$TASK_BRANCH" "$TASK_COMMIT"
cat "$TASK_TEMP/SHA256SUMS.txt"
if [[ "$TASK_DRY_RUN" == 1 ]]; then
    printf 'Dry run complete. No refs, tags, releases, or remote state were changed.\n'
    exit 0
fi
[[ "$(git rev-parse HEAD)" == "$TASK_HEAD" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source changed during validation.'
# No force push: races with another publisher must fail rather than replace an artifact.
git push origin "$TASK_COMMIT:refs/heads/$TASK_BRANCH"
git -c tag.gpgSign=false tag -a "$TASK_TAG" "$TASK_HEAD" -m "FileDock $TASK_TAG; source $TASK_HEAD; assets $TASK_COMMIT"
git push origin "refs/tags/$TASK_TAG:refs/tags/$TASK_TAG"
printf 'Tag pushed. GitHub Actions will validate and publish the release.\nAfter verifying the published assets, remove only the temporary branch:\n  git push origin --delete %s\n' "$TASK_BRANCH"
