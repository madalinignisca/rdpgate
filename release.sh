#!/usr/bin/env bash
# Build, sign, notarize and staple a release of RDPGate.app.
#
#   RDPGATE_SIGN_ID="Developer ID Application: …" \
#   RDPGATE_NOTARY_PROFILE=<notarytool keychain profile> \
#   ./release.sh X.Y.Z
#
# Produces dist/RDPGate-<version>-<arch>.zip for this Mac's architecture.
# Nothing here is public: Apple receives the build for notarization, and
# publishing is a separate step (publish.sh).
#
# Every step aborts on failure. A release that cannot show each property —
# right architecture, hardened runtime, notarized, stapled, no local paths —
# is not produced at all.
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "release: $*" >&2; exit 1; }

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh X.Y.Z"
[[ -n ${RDPGATE_SIGN_ID:-} ]]        || die "set RDPGATE_SIGN_ID to your Developer ID Application identity"
[[ -n ${RDPGATE_NOTARY_PROFILE:-} ]] || die "set RDPGATE_NOTARY_PROFILE to a 'notarytool store-credentials' profile"

# One architecture per release asset. Intel builds are made on an Intel Mac
# with this same script; see README, "Releasing".
ARCH=${ARCH:-$(uname -m)}
APP="RDPGate.app"
BIN="$APP/Contents/MacOS/RDPGate"
BUNDLE_ID="me.madalin.rdpgate"   # the cask's `uninstall quit:` relies on it
DIST="dist"
FINAL="$DIST/RDPGate-$VERSION-$ARCH.zip"

# Released versions are immutable: a published zip is never replaced in place.
[[ ! -e $FINAL ]] || die "$FINAL already exists — bump the version instead of rebuilding it"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  die "tag v$VERSION already exists — that version is released; bump it"
fi
mkdir -p "$DIST"

echo "==> build"
ARCH="$ARCH" ./build.sh release "$VERSION"

echo "==> check build"
[[ $(lipo -archs "$BIN") == "$ARCH" ]] || die "binary is '$(lipo -archs "$BIN")', expected '$ARCH'"
vtool -show-build "$BIN" | grep -q 'minos 14.0' || die "minimum macOS is not 14.0"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") == "$BUNDLE_ID" ]] \
  || die "bundle identifier is not $BUNDLE_ID"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") == "$VERSION" ]] \
  || die "Info.plist version does not match $VERSION"

# Before signing, so the certificate's own subject (which names the signer, and
# is accepted as public) is not what this check looks at. Fails closed: a tool
# error is a failure, not "no matches".
echo "==> privacy check"
STRS=$(strings -a "$BIN") || die "could not extract strings from $BIN"
[[ -n $STRS ]] || die "no strings extracted from $BIN"
set +e
HITS=$(grep -E '/Users/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$STRS")
RC=$?
set -e
case $RC in
  1) ;;                                   # no matches: clean
  0) echo "$HITS" >&2; die "the binary contains local paths or e-mail addresses (listed above)" ;;
  *) die "privacy check failed to run (grep exit $RC)" ;;
esac

echo "==> sign (Developer ID, hardened runtime, no entitlements)"
# No entitlements and no App Sandbox: hardened runtime alone does not stop the
# app from launching Homebrew's FreeRDP or writing the password to its stdin;
# the sandbox would break both.
codesign --force --options runtime --timestamp --sign "$RDPGATE_SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
SIGNINFO=$(codesign -dvv "$APP" 2>&1)
grep -q 'flags=0x10000(runtime)'          <<<"$SIGNINFO" || die "hardened runtime flag missing"
grep -q '^Timestamp='                     <<<"$SIGNINFO" || die "secure timestamp missing"
grep -q '^Authority=Developer ID Application' <<<"$SIGNINFO" || die "not signed with a Developer ID Application identity"

echo "==> notarize (uploads the build to Apple and waits)"
SUBMIT="$DIST/.RDPGate-$VERSION-$ARCH-notarize.zip"
rm -f "$SUBMIT"
ditto -c -k --keepParent "$APP" "$SUBMIT"
RESULT=$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$RDPGATE_NOTARY_PROFILE" \
           --wait --output-format json) || true
STATUS=$(plutil -extract status raw -o - - <<<"$RESULT" 2>/dev/null || echo "unknown")
SUBMISSION=$(plutil -extract id raw -o - - <<<"$RESULT" 2>/dev/null || echo "")
rm -f "$SUBMIT"
if [[ $STATUS != "Accepted" ]]; then
  if [[ -n $SUBMISSION ]]; then
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$RDPGATE_NOTARY_PROFILE" \
      "$DIST/notarization-$VERSION-$ARCH.json" || true
  fi
  echo "$RESULT" >&2
  die "notarization status '$STATUS' (log, if any, in $DIST/)"
fi

echo "==> staple and assess"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ASSESS=$(spctl -a -vv -t exec "$APP" 2>&1) || die "Gatekeeper rejected the app: $ASSESS"
grep -q 'source=Notarized Developer ID' <<<"$ASSESS" || die "Gatekeeper source is not 'Notarized Developer ID': $ASSESS"

echo "==> package"
# The shipped zip holds the *stapled* app, so Gatekeeper can verify it offline.
# Written under a temporary name and renamed only once complete, so a partial
# zip can never look like a finished release to publish.sh.
TMP="$DIST/.RDPGate-$VERSION-$ARCH.zip.tmp"
rm -f "$TMP"
ditto -c -k --keepParent "$APP" "$TMP"
mv "$TMP" "$FINAL"
SHA=$(shasum -a 256 "$FINAL" | cut -d' ' -f1)

echo
echo "Release ready: $FINAL"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
echo "Publish with:  RDPGATE_TAP_DIR=<tap clone> ./publish.sh $VERSION"
