#!/bin/bash
# Run this ONCE, interactively, from your own terminal. It needs your login password and
# cannot be completed by an automated agent -- both steps raise GUI dialogs, and an agent's
# codesign call times out before anyone can click them.
#
#   1. Trust the self-signed certificate for code signing. Without it codesign reports
#      CSSMERR_TP_NOT_TRUSTED and refuses the identity.
#   2. Add codesign to the private key's partition list. Without it EVERY signing operation
#      raises a "codesign wants to access key" dialog -- including every rebuild, and
#      including ones triggered by an agent that cannot answer them.
#
# Step 2 is the one people miss. Clicking "Always Allow" on the dialog usually sets it, but
# the partition list is the reliable, scriptable form.

# -e is deliberately omitted: the `|| echo` fallbacks below are the error handling, and
# -e would abort before they run. Do not "fix" this.
set -uo pipefail
cd "$(dirname "$0")/.."

# Pin PATH: this script establishes a code-signing trust anchor. A user-writable directory
# ahead of /usr/bin (npm, homebrew, conda all install there) could shim `security` and own
# the operation outright.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

CERT_NAME="apple-calendar-mcp local signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_PEM="$HOME/.local/state/apple-calendar-mcp/signing-cert.pem"

if [ -f "$CERT_PEM" ]; then
    echo "==> Trusting '$CERT_NAME' for code signing"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" \
      && echo "    trusted" || echo "    (already trusted, or you cancelled)"
else
    echo "==> No exported certificate at $CERT_PEM -- skipping trust step"
fi

echo
echo "==> Allowing codesign to use the private key without prompting"
echo "    (security will ask for your login password itself)"
# Deliberately NOT passing -k "$password". An argument vector is readable by every process
# running as this user, and the login keychain password is the highest-value secret on the
# machine. Letting `security` prompt on its own tty keeps it out of argv entirely.
# -l "$CERT_NAME" scopes this to OUR key. Without it, -s matches EVERY sign-capable key in
# the login keychain, and set-key-partition-list REPLACES a partition list rather than
# appending -- so an unscoped run rewrites the partition lists of every other signing key
# you own (Developer ID, S/MIME, client-auth), breaking other applications' access to their
# own keys and granting codesign promptless access to keys unrelated to this project.
#
# Subtlety worth preserving: -s is a boolean match filter that takes NO argument. "$KEYCHAIN"
# is consumed by the trailing positional [keychain] parameter, not by -s. Do not "fix" the
# apparent mismatch.
if PARTITION_ERR=$(security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -l "$CERT_NAME" "$KEYCHAIN" 2>&1 >/dev/null); then
    echo "    partition list updated"
else
    echo "    FAILED:"
    echo "$PARTITION_ERR" | sed 's/^/      /'
fi

echo
echo "==> Signing identities:"
security find-identity -v -p codesigning

echo
echo "Now verify signing works without a dialog:"
echo "  ./scripts/sign.sh"
