#!/bin/zsh
# Publishes a new Cadre version on GitHub Releases, where the app's updater finds it.
# Usage: Scripts/release.sh 1.1.0 "What changed"
set -euo pipefail

cd "$(dirname "$0")/.."
NEW="${1:?usage: Scripts/release.sh X.Y.Z \"release notes\"}"
NOTES="${2:-Cadre $NEW}"

[[ "$NEW" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
if git rev-parse "v$NEW" >/dev/null 2>&1; then echo "Tag v$NEW already exists."; exit 1; fi

echo "$NEW" > VERSION
swift test
./Scripts/build-app.sh
rm -f build/Cadre.zip
ditto -c -k --keepParent build/Cadre.app build/Cadre.zip

if ! git diff --quiet VERSION; then
  git add VERSION
  git commit -m "Release $NEW"
fi
git tag "v$NEW"
git push origin HEAD "v$NEW"
gh release create "v$NEW" build/Cadre.zip --title "Cadre $NEW" --notes "$NOTES"
echo "Released Cadre $NEW"
