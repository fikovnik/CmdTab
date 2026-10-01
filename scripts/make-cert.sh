#!/usr/bin/env bash
# Create a self-signed code-signing certificate in the login keychain.
#
# macOS keeps the Accessibility permission for a designated requirement. The
# requirement of an ad-hoc signature is `cdhash H"..."`, which changes on each
# build. Thus, each build loses the permission. With a certificate, the
# requirement is `identifier "..." and certificate leaf H"..."`. This does not
# change while the certificate is valid.
#
# If the certificate exists, the script does nothing.
set -euo pipefail

NAME="${1:-CmdTab Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Use LibreSSL, not Homebrew OpenSSL 3. `security import` can read the default
# PKCS#12 encryption of LibreSSL without the -legacy flag.
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

# `security import` refuses a PKCS#12 file with an empty password ("MAC
# verification failed"). Thus, use a random password. The file stays in $TMP.
PASS="$(uuidgen)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"

# With -A, codesign can use the private key without a keychain prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -A

echo "created certificate '$NAME'"
