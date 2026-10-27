#!/bin/bash
# Creates a local self-signed code-signing identity "RemoteMyMac Local" (once) so macOS privacy grants survive rebuilds.
set -euo pipefail
NAME="RemoteMyMac Local"
if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/o.cnf" <<C
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
C
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$D/k.pem" -out "$D/c.pem" -config "$D/o.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$D/k.pem" -in "$D/c.pem" -out "$D/i.p12" -passout pass:rmm -legacy 2>/dev/null || \
openssl pkcs12 -export -inkey "$D/k.pem" -in "$D/c.pem" -out "$D/i.p12" -passout pass:rmm
security import "$D/i.p12" -k ~/Library/Keychains/login.keychain-db -P rmm -T /usr/bin/codesign
