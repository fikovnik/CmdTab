#!/usr/bin/env bash
# Create a self-signed code-signing certificate in the login keychain.
#
# Why: an ad-hoc signature's designated requirement is `cdhash H"..."`, which
# changes on every build. macOS keys the Accessibility grant to that
# requirement, so every rebuild silently drops the permission. Signing with a
# real certificate makes the requirement `identifier "..." and certificate leaf
# H"..."` instead, which is stable for the life of the certificate.
#
# Idempotent: does nothing if the certificate already exists.
set -euo pipefail

NAME="${1:-CmdTab Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL, not Homebrew OpenSSL 3: its default PKCS#12 encryption is the one
# `security import` can actually read, with no -legacy flag needed.
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

# `security import` rejects an empty-password PKCS#12 ("MAC verification
# failed"), so use a throwaway one; the file never leaves $TMP.
PASS="$(uuidgen)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

# -A lets codesign use the private key without a keychain prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -A

echo "created certificate '$NAME'"
