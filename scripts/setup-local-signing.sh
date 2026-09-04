#!/bin/zsh

set -euo pipefail

signing_name="StreamTranslate Local Code Signing"
login_keychain="$HOME/Library/Keychains/login.keychain-db"

find_identity() {
    security find-identity -v -p codesigning "$login_keychain" 2>/dev/null \
        | awk -v needle="\"$signing_name\"" 'index($0, needle) { print $2; exit }'
}

if [[ -n "$(find_identity)" ]]; then
    echo "$signing_name is already available."
    exit 0
fi

signing_tmp=$(mktemp -d)
cleanup() {
    find "$signing_tmp" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

if security find-certificate -c "$signing_name" "$login_keychain" >/dev/null 2>&1; then
    security find-certificate -c "$signing_name" -p "$login_keychain" \
        > "$signing_tmp/certificate.pem"
else
    p12_password=$(openssl rand -hex 24)
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -subj "/CN=$signing_name/O=StreamTranslate Local Development" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=codeSigning' \
        -keyout "$signing_tmp/private-key.pem" \
        -out "$signing_tmp/certificate.pem" >/dev/null 2>&1
    openssl pkcs12 -export -legacy \
        -inkey "$signing_tmp/private-key.pem" \
        -in "$signing_tmp/certificate.pem" \
        -name "$signing_name" \
        -passout "pass:$p12_password" \
        -out "$signing_tmp/identity.p12"
    security import "$signing_tmp/identity.p12" \
        -k "$login_keychain" \
        -P "$p12_password" \
        -T /usr/bin/codesign >/dev/null
fi

echo "macOS may request the login password to trust the local signing certificate."
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$signing_tmp/certificate.pem" >/dev/null

identity_hash=$(find_identity)
if [[ -z "$identity_hash" ]]; then
    echo "Failed to create a valid $signing_name identity." >&2
    exit 1
fi

echo "$signing_name is ready: $identity_hash"
