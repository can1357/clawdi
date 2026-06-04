#!/usr/bin/env bash
# Upload Clawdi's macOS signing and notarization secrets without printing values.
#
# Prepare a directory containing:
#   *.p12                 Developer ID Application identity exported from Keychain Access.
#   p12-password.txt      Password set during the .p12 export.
#   AuthKey_<KEYID>.p8    App Store Connect API key, downloaded once.
#   issuer-id.txt         App Store Connect API issuer UUID.
#   key-id.txt            Optional when the .p8 name contains the key ID.
#
# Usage:
#   Tools/release/upload-secrets.sh [directory] [--dry-run]
#   CLAWDI_REPO=owner/repo Tools/release/upload-secrets.sh ~/clawdi-signing

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
directory=""
dry_run=0
for argument in "$@"; do
    case "$argument" in
    --dry-run) dry_run=1 ;;
    *) directory="$argument" ;;
    esac
done
directory="${directory:-${CLAWDI_SIGNING_DIR:-$HOME/clawdi-signing}}"
repo="${CLAWDI_REPO:-$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner)}"

die() {
    echo "upload-secrets: $1" >&2
    exit 1
}

[[ -d "$directory" ]] || die "directory not found: $directory"

find_one() {
    local pattern="$1" matches=()
    while IFS= read -r file; do matches+=("$file"); done < <(find "$directory" -maxdepth 1 -type f -name "$pattern" | sort)
    ((${#matches[@]} == 1)) || die "expected exactly one '$pattern' in $directory, found ${#matches[@]}"
    printf '%s' "${matches[0]}"
}

read_value() {
    local path="$1" name="$2" value
    [[ -f "$path" ]] || die "missing $name file: $path"
    value="$(cat "$path")"
    [[ -n "$value" ]] || die "$name file is empty: $path"
    printf '%s' "$value"
}

p12="$(find_one '*.p12')"
p8="$(find_one '*.p8')"
password="$(read_value "$directory/p12-password.txt" 'p12-password.txt')"
issuer="$(read_value "$directory/issuer-id.txt" 'issuer-id.txt')"

if [[ -f "$directory/key-id.txt" ]]; then
    key_id="$(read_value "$directory/key-id.txt" 'key-id.txt')"
else
    key_id="$(basename "$p8" .p8)"
    key_id="${key_id#AuthKey_}"
    [[ -n "$key_id" && "$key_id" != "$(basename "$p8" .p8)" ]] \
        || die "could not derive key ID from $(basename "$p8"); add key-id.txt"
fi

validation_keychain="$(mktemp -d)/validate.keychain-db"
validation_password="$(openssl rand -hex 16)"
cleanup() {
    security delete-keychain "$validation_keychain" >/dev/null 2>&1 || true
}
trap cleanup EXIT

security create-keychain -p "$validation_password" "$validation_keychain" >/dev/null
security unlock-keychain -p "$validation_password" "$validation_keychain" >/dev/null
security import "$p12" -P "$password" -k "$validation_keychain" -T /usr/bin/codesign >/dev/null
security find-identity -v -p codesigning "$validation_keychain" | grep -q 'Developer ID Application' \
    || die 'the .p12 contains no Developer ID Application identity'
grep -q 'BEGIN PRIVATE KEY' "$p8" || die 'the .p8 does not look like a PEM private key'

echo "upload-secrets: repo=$repo"
echo "  certificate: $(basename "$p12")"
echo "  API key: $(basename "$p8") (key ID $key_id)"
echo '  secrets: APPLE_CERTIFICATE_P12, APPLE_CERTIFICATE_PASSWORD, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY'

if ((dry_run)); then
    echo 'upload-secrets: --dry-run, not uploading'
    exit 0
fi

set_secret() {
    gh secret set "$1" --repo "$repo"
}

base64 <"$p12" | tr -d '\n' | set_secret APPLE_CERTIFICATE_P12
printf '%s' "$password" | set_secret APPLE_CERTIFICATE_PASSWORD
printf '%s' "$key_id" | set_secret APPLE_API_KEY_ID
printf '%s' "$issuer" | set_secret APPLE_API_ISSUER_ID
base64 <"$p8" | tr -d '\n' | set_secret APPLE_API_KEY

echo "upload-secrets: done. Verify with: gh secret list --repo $repo"