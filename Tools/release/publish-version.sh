#!/usr/bin/env bash
# Bump the app version, publish its commit, then create and publish the matching release tag.
#
# Usage:
#   Tools/release/publish-version.sh major|minor|patch

set -euo pipefail

part="${1:-}"
case "$part" in
major|minor|patch) ;;
*)
    echo "usage: Tools/release/publish-version.sh major|minor|patch" >&2
    exit 64
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plist="$root/Sources/Clawdi/App/Info.plist"
cd "$root"

branch="$(git branch --show-current)"
[[ "$branch" == "main" ]] || {
    echo "publish-version: release from main, not $branch" >&2
    exit 65
}
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "publish-version: commit or discard working tree changes first" >&2
    exit 66
fi

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "publish-version: expected MAJOR.MINOR.PATCH, got $current" >&2
    exit 67
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
case "$part" in
major) next="$((major + 1)).0.0" ;;
minor) next="$major.$((minor + 1)).0" ;;
patch) next="$major.$minor.$((patch + 1))" ;;
esac

tag="v$next"
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    echo "publish-version: $tag already exists on origin" >&2
    exit 68
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$plist"
git add "$plist"
git commit -m "chore: bumped version to $next" -m "Published the matching $tag GitHub release tag."
git push origin "$branch"
git tag -a "$tag" -m "clawdi $next"
git push origin "$tag"

echo "publish-version: published $tag"