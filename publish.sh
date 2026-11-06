#!/usr/bin/env bash
# Publish a release made by release.sh: tag, GitHub release, Homebrew tap.
#
#   RDPGATE_TAP_DIR=<clone of homebrew-rdpgate> ./publish.sh X.Y.Z
#
# Everything this script does is public and outward-facing. Run it only once
# the release is final.
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "publish: $*" >&2; exit 1; }

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: publish.sh X.Y.Z"
[[ -n ${RDPGATE_TAP_DIR:-} && -d ${RDPGATE_TAP_DIR:-} ]] || die "set RDPGATE_TAP_DIR to the tap clone"

# The cask is single-architecture (arm64) for now: its URL and sha256 describe
# the arm64 zip only. Publishing any other zip here would write a checksum that
# does not match what the cask downloads. See README, "Architectures".
ARCH="arm64"
ZIP="dist/RDPGate-$VERSION-$ARCH.zip"
CASK="$RDPGATE_TAP_DIR/Casks/rdpgate.rb"
# Commits in both repos are authored with GitHub's noreply address, so no
# personal e-mail is published. Checked rather than assumed: a fresh clone
# falls back to the global git identity.
NOREPLY="619561+madalinignisca@users.noreply.github.com"

[[ -f $ZIP ]]  || die "$ZIP not found — run release.sh $VERSION first"
[[ -f $CASK ]] || die "$CASK not found"
[[ -z $(git status --porcelain) ]] || die "working tree is not clean"
# The tap may only be dirty in the cask itself — the state a previous run leaves
# if it stopped between editing and committing.
TAPDIRT=$(git -C "$RDPGATE_TAP_DIR" status --porcelain)
[[ -z $TAPDIRT || $TAPDIRT =~ ^(\ M|M\ |MM)\ Casks/rdpgate\.rb$ ]] \
  || die "tap has changes other than Casks/rdpgate.rb: $TAPDIRT"
[[ $(git config user.email) == "$NOREPLY" ]] || die "repo user.email is not $NOREPLY"
[[ $(git -C "$RDPGATE_TAP_DIR" config user.email) == "$NOREPLY" ]] || die "tap user.email is not $NOREPLY"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
NAME=$(basename "$ZIP")

# Release notes are the version's CHANGELOG.md section: from its "## X.Y.Z"
# heading up to the next "## ". Checked before anything is pushed, so a release
# can't go out with no notes. They can still be edited on GitHub afterwards.
NOTES=$(awk -v h="## $VERSION" '$0==h{f=1;next} f&&/^## /{exit} f' CHANGELOG.md)
[[ -n ${NOTES//[[:space:]]/} ]] || die "CHANGELOG.md has no '## $VERSION' section"
NOTES+=$'\n\n'"Install or upgrade: \`brew install --cask madalinignisca/rdpgate/rdpgate\`"

echo "==> push branch"
# Before the tag, so the released commit is on a branch on GitHub, not only
# reachable through the tag.
git push -u origin "$(git branch --show-current)"

echo "==> tag v$VERSION"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  [[ $(git rev-parse "v$VERSION^{commit}") == $(git rev-parse HEAD) ]] \
    || die "tag v$VERSION exists and does not point at HEAD"
else
  git tag -a "v$VERSION" -m "RDPGate $VERSION"
fi
git push origin "v$VERSION"

echo "==> GitHub release"
# Rerunnable: if a previous run stopped after creating the release, reuse it
# (the asset check below still decides whether the tap may be updated).
if ! gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release create "v$VERSION" "$ZIP" --verify-tag --title "RDPGate $VERSION" \
    --notes "$NOTES"
fi
# A previous run may have created the release but failed the upload. Upload
# only when the asset is missing — never --clobber an existing one, since a
# published file must not change under the same version.
# Captured first, not piped into grep -q: under pipefail an early-exiting grep
# can SIGPIPE gh and make "asset present" read as "asset missing".
ASSETS=$(gh release view "v$VERSION" --json assets --jq '.assets[].name')
if ! grep -qx "$NAME" <<<"$ASSETS"; then
  gh release upload "v$VERSION" "$ZIP"
fi

# The tap is only touched once the download provably exists and matches:
# a cask pointing at a missing or different file breaks every install.
echo "==> verify uploaded asset"
UPLOADED=$(gh release download "v$VERSION" --pattern "$NAME" --output - | shasum -a 256 | cut -d' ' -f1)
[[ $UPLOADED == "$SHA" ]] || die "uploaded $NAME does not match the local zip; tap NOT updated"

echo "==> update tap"
# Single-architecture cask for now. When an Intel build is added, the cask
# switches to per-architecture sha256 values and this edit must change with it.
sed -i '' -E \
  -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" \
  "$CASK"
grep -q "^  version \"$VERSION\"$" "$CASK" || die "version not updated in $CASK"
grep -q "^  sha256 \"$SHA\"$" "$CASK"      || die "sha256 not updated in $CASK"
brew style "$CASK"
git -C "$RDPGATE_TAP_DIR" add Casks/rdpgate.rb
# Commit only if something changed (a rerun after a failed push has nothing
# new to commit); push unconditionally, which is a no-op when up to date.
if ! git -C "$RDPGATE_TAP_DIR" diff --cached --quiet; then
  git -C "$RDPGATE_TAP_DIR" commit -m "rdpgate $VERSION"
fi
git -C "$RDPGATE_TAP_DIR" push -u origin "$(git -C "$RDPGATE_TAP_DIR" branch --show-current)"

echo
echo "Published RDPGate $VERSION:"
echo "  brew install --cask madalinignisca/rdpgate/rdpgate"
