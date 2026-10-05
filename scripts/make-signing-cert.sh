#!/usr/bin/env bash
# Makes a self-signed code-signing certificate, "Loam Local Signing", in your
# login keychain, so install.sh can sign Loam.app with a stable identity and
# macOS keeps Loam's permissions across rebuilds. No Apple account needed.
# Safe to run again: it stops if the identity already exists.
#
# Usage: scripts/make-signing-cert.sh
set -euo pipefail

name="Loam Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "The certificate \"$name\" is already in your login keychain."
  security find-identity -v -p codesigning | grep "$name" || true
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=$(openssl rand -hex 16)

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

# macOS's keychain reads only the older PKCS#12 algorithms. OpenSSL 3 needs
# -legacy for them; LibreSSL uses them by default.
legacy=()
if openssl version | grep -q '^OpenSSL 3'; then legacy=(-legacy); fi
openssl pkcs12 -export "${legacy[@]}" -name "$name" \
  -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/cert.p12" -passout "pass:$pass"

security import "$work/cert.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Imported \"$name\" into your login keychain."

echo "macOS now asks for your password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

security find-identity -v -p codesigning | grep "$name"
echo "Done. scripts/install.sh app now signs with \"$name\"."
