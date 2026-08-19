#!/bin/bash
# Create a STABLE self-signed code-signing certificate in the login keychain.
#
# Why not ad-hoc (`codesign -s -`)? TCC pins the Calendar grant to the binary's cdhash via
# its designated requirement. An ad-hoc signature carries no stable identity, so every
# `swift build` produces a binary macOS treats as a different program -- and the grant is
# lost. Silently, per the note in Entitlements.plist. Hundreds of lost grants during
# development, and one on every consumer's `git pull && swift build`.
#
# Run once per machine. Idempotent.

set -euo pipefail
cd "$(dirname "$0")/.."

CERT_NAME="apple-calendar-mcp local signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Use the SYSTEM openssl deliberately. Homebrew/conda ship OpenSSL 3, whose default PKCS12
# algorithms (AES-256-CBC + SHA-256) the macOS Security framework rejects with a misleading
# "MAC verification failed (wrong password?)" -- the password is fine, the cipher is not.
# macOS LibreSSL produces a bundle the keychain imports natively.
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Identity already present: $CERT_NAME"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = apple-calendar-mcp local signing
O  = apple-calendar-mcp
C  = US

[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "Generating self-signed code-signing certificate..."
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null

# A transient password, not an empty one. With an empty password OpenSSL and the macOS
# Security framework disagree on how to encode it when computing the PKCS12 MAC, which
# surfaces as "MAC verification failed (wrong password?)". The bundle is deleted seconds
# later either way.
P12PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"

echo "Packaging..."
# -passout fd:3 instead of pass:VALUE -- an argument vector is world-readable to every
# process running as this user (ps auxww, sysctl kern.procargs2).
"$OPENSSL" pkcs12 -export -out "$WORK/cert.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -passout fd:3 2>/dev/null 3<<<"$P12PASS"

echo "Importing into the login keychain..."
# KNOWN TRADEOFF: `security import` offers no way to supply the password other than argv,
# so this one value is briefly visible to `ps` for other processes running as this user.
# Accepted because the secret is a random 32-char string generated seconds ago, protecting
# a .p12 that is deleted moments later, and it is never reused. The login keychain password
# is NOT handled this way -- see trust-signing-cert.sh, which lets `security` prompt.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# The trust script needs this file. Without it, its trust step silently no-ops and the
# user gets CSSMERR_TP_NOT_TRUSTED from sign.sh with no path to recovery.
install -d -m 700 "$HOME/.local/state/apple-calendar-mcp"
install -m 600 "$WORK/cert.pem" "$HOME/.local/state/apple-calendar-mcp/signing-cert.pem"
echo "Certificate saved to ~/.local/state/apple-calendar-mcp/signing-cert.pem"

echo "Marking it trusted for code signing..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null || {
    echo "  (trust settings not applied automatically -- usually fine for local signing)"
}

echo
echo "Available code-signing identities:"
security find-identity -v -p codesigning
