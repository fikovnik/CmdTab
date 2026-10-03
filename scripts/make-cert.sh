#!/usr/bin/env bash
# Create a stable signing identity in the login keychain.
# A certificate-based designated requirement stays constant between builds.
# An ad hoc signature uses the binary hash and changes on each build.
# Keep an existing certificate.
set -euo pipefail

NAME="${1:-CmdTab Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Use the system LibreSSL format for compatibility with security import.
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "certificate '$NAME' already present"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Use a temporary random password because security import refuses an empty password.
PASS="$(uuidgen)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

# Permit codesign to use the imported key without a keychain prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -A

echo "created certificate '$NAME'"
