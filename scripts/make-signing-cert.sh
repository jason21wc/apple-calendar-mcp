#!/bin/bash
# Create a STABLE self-signed code-signing certificate in the login keychain.
#
# Why not ad-hoc (`codesign -s -`)? Because of what the Calendar grant is checked against.
# TCC stores a designated requirement alongside the grant. Signed with a certificate, that
# requirement reads:
#
#     identifier "<bundle id>" and certificate root = H"<cert hash>"
#
# which is IDENTITY-based, so any later build signed by the same certificate still
# satisfies it and the grant survives rebuilds (measured across a real cdhash change).
# An ad-hoc signature has no certificate, so the requirement falls back to the cdhash --
# which changes on every `swift build`. The grant is then lost silently, per the note in
# Entitlements.plist: hundreds of times during development, and once on every consumer's
# `git pull && swift build`.
#
# Separately: the grant is keyed to the binary's ABSOLUTE PATH, so a stable certificate
# does not save you from moving or reinstalling the binary. Re-run --grant at the new path.
#
# Run once per machine. Idempotent.

set -euo pipefail
cd "$(dirname "$0")/.."

# Pin PATH: this script creates the machine's code-signing trust anchor for this tool. A
# shimmed `security`, `codesign` or `install` earlier in PATH would compromise it. (This is
# also why OPENSSL below is an absolute path -- see the OpenSSL 3 note there.)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

CERT_NAME="apple-calendar-mcp local signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Use the SYSTEM openssl deliberately. Homebrew/conda ship OpenSSL 3, whose default PKCS12
# algorithms (AES-256-CBC + SHA-256) the macOS Security framework rejects with a misleading
# "MAC verification failed (wrong password?)" -- the password is fine, the cipher is not.
# macOS LibreSSL produces a bundle the keychain imports natively.
OPENSSL=/usr/bin/openssl

# NOTE: `case`, not `grep -q`. Any pipeline ending in `grep -q` can invert under
# `set -o pipefail`: grep exits on first match, the upstream command takes SIGPIPE (141),
# and pipefail makes that the pipeline's status -- so a SUCCESSFUL match reads as failure.
# Capturing to a variable first does NOT fix it; the pipeline is still there. Measured.
# `case` does no I/O and cannot be raced.
#
# This site was a real defect: it reported a PRESENT identity as absent, so a second run
# minted a SECOND certificate. The existing Calendar grant's designated requirement names
# the FIRST certificate's root, so the effect was silent loss of Calendar access.
EXISTING_IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
case "$EXISTING_IDS" in
    *"$CERT_NAME"*)
        echo "Identity already present: $CERT_NAME"
        printf '%s\n' "$EXISTING_IDS" | sed -n "/$CERT_NAME/p" || true
        exit 0
        ;;
esac

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
# No pipe: `tr </dev/urandom | head -c 32` makes head exit first, tr takes SIGPIPE (141),
# and `set -o pipefail` aborts the whole script -- silently, right after "Generating...".
P12PASS="$("$OPENSSL" rand -hex 16)"

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
    echo "  WARNING: trust settings were NOT applied."
    echo "  codesign will report CSSMERR_TP_NOT_TRUSTED and refuse the identity."
    echo "  Run ./scripts/trust-signing-cert.sh to apply them interactively."
}

echo
echo "Available code-signing identities:"
security find-identity -v -p codesigning
