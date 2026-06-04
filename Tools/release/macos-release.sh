#!/usr/bin/env bash
# Builds, signs, notarizes, and archives Clawdi for a GitHub Release.
#
# Required environment:
#   APPLE_CERTIFICATE_P12        Base64-encoded Developer ID Application .p12.
#   APPLE_CERTIFICATE_PASSWORD   Password protecting the .p12.
#   APPLE_API_KEY_ID             App Store Connect API key ID.
#   APPLE_API_ISSUER_ID          App Store Connect API issuer UUID.
#   APPLE_API_KEY                Base64-encoded App Store Connect .p8 key.
#
# Optional environment:
#   RELEASE_ARCHIVE              Destination for the notarized zip archive.

set -euo pipefail

if [[ "${OSTYPE:-}" != darwin* ]]; then
    echo "macos-release: must run on macOS" >&2
    exit 1
fi

missing=()
for variable in APPLE_CERTIFICATE_P12 APPLE_CERTIFICATE_PASSWORD APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY; do
    [[ -n "${!variable:-}" ]] || missing+=("$variable")
done
if ((${#missing[@]})); then
    echo "macos-release: missing required environment: ${missing[*]}" >&2
    exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$root/DerivedData/Build/Products/Release/Clawdi.app"
archive="${RELEASE_ARCHIVE:-$root/Clawdi-macos-universal.zip}"
workdir="$(mktemp -d)"
keychain="$workdir/clawdi-signing.keychain-db"
keychain_password="$(openssl rand -hex 24)"
certificate="$workdir/certificate.p12"
api_key="$workdir/api-key.p8"
notary_archive="$workdir/Clawdi.zip"

cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode >"$certificate"
printf '%s' "$APPLE_API_KEY" | base64 --decode >"$api_key"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
existing_keychains="$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')"
# shellcheck disable=SC2086 # Existing keychain paths intentionally expand as separate arguments.
security list-keychains -d user -s "$keychain" $existing_keychains
security import "$certificate" -P "$APPLE_CERTIFICATE_PASSWORD" -k "$keychain" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

identity="$(security find-identity -v -p codesigning "$keychain" | sed -nE 's/.*"([^"]*Developer ID Application[^"]*)".*/\1/p' | head -n 1)"
if [[ -z "$identity" ]]; then
    echo "macos-release: no Developer ID Application identity in imported certificate" >&2
    security find-identity -v -p codesigning "$keychain" >&2 || true
    exit 1
fi
team="$(printf '%s' "$identity" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"
if [[ -z "$team" ]]; then
    echo "macos-release: could not determine the signing team from '$identity'" >&2
    exit 1
fi

cd "$root"
xcodegen generate
xcodebuild \
    -project Clawdi.xcodeproj \
    -scheme Clawdi \
    -configuration Release \
    -derivedDataPath DerivedData \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" \
    DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

codesign --verify --deep --strict --verbose=4 "$app"
codesign -dvvv "$app" 2>&1 | grep -E 'Authority|TeamIdentifier|flags=|Timestamp'

rm -f "$archive" "$notary_archive"
ditto -c -k --keepParent "$app" "$notary_archive"
submit_json="$(xcrun notarytool submit "$notary_archive" \
    --key "$api_key" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --timeout 30m \
    --output-format json)"
echo "$submit_json"
read -r status submission_id <<<"$(printf '%s' "$submit_json" | python3 -c 'import json,sys; result=json.load(sys.stdin); print(result.get("status", ""), result.get("id", ""))')"
if [[ "$status" != "Accepted" ]]; then
    echo "macos-release: notarization status=$status (expected Accepted)" >&2
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" \
            --key "$api_key" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" >&2 || true
    fi
    exit 1
fi

xcrun stapler staple "$app"
codesign --verify --deep --strict --verbose=4 "$app"
spctl --assess --type execute --verbose=4 "$app"
ditto -c -k --keepParent "$app" "$archive"
echo "macos-release: created $archive"