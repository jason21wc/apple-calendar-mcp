#!/bin/bash
# Sign the built binary with the stable self-signed identity, the calendars entitlement,
# and the hardened runtime.
#
# All three are required together. Hardened runtime WITHOUT the entitlement is the worst
# case: on macOS 26.5 tccd then refuses to show any Calendar prompt at all, permanently,
# while every status API still reports green.

set -euo pipefail

# Pin PATH. This script invokes codesign, security and plutil; a shimmed `codesign` earlier
# in PATH would own the signing operation outright. User-writable directories (npm,
# homebrew, conda) commonly precede /usr/bin on a developer machine.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Resolve the argument against the caller's cwd BEFORE moving to the repo root, so a
# relative path still means what the caller meant.
if [ $# -ge 1 ]; then
    case "$1" in
        /*) ARG_BIN="$1" ;;
        *)  ARG_BIN="$PWD/$1" ;;
    esac
fi

# The entitlements path below is repo-relative, so run from the package root regardless of
# where the caller invoked this from.
cd "$(dirname "$0")/.."

CERT_NAME="apple-calendar-mcp local signing"
BIN="${ARG_BIN:-.build/release/apple-calendar-mcp}"
ENTITLEMENTS="Sources/apple-calendar-mcp/Entitlements.plist"

[ -f "$BIN" ] || { echo "No binary at $BIN. Run: swift build -c release"; exit 1; }

# codesign rewrites the file in place, so an unwritable target fails with
# "internal error in Code Signing subsystem" -- which names neither the cause nor the fix.
# Say it plainly instead.
if [ ! -w "$BIN" ]; then
    echo "Cannot write to $BIN (owned by $(stat -f '%Su' "$BIN"))."
    echo
    echo "You usually do NOT need to sign after installing: cp preserves the embedded"
    echo "signature, so a binary signed before copying is still correctly signed. Verify"
    echo "with:  codesign --verify --strict \"$BIN\""
    echo
    echo "If you really do need to re-sign in place, use: sudo \"$0\" \"$BIN\""
    exit 1
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
if ! printf '%s' "$IDENTITIES" | grep -q "$CERT_NAME"; then
    echo "No valid signing identity found."
    echo "Run ./scripts/make-signing-cert.sh, then ./scripts/trust-signing-cert.sh"
    exit 1
fi

echo "==> Signing $BIN"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    -s "$CERT_NAME" \
    "$BIN"

echo "==> Verifying"
codesign --verify --strict --verbose=2 "$BIN"

# ASSERT, do not merely display. A hardened-runtime binary missing the calendars
# entitlement gets no Calendar prompt at all on macOS 26.5 -- silently and permanently,
# while every status API still reports green. A build that signs wrongly must fail loudly
# here rather than surface hours later as an unexplained denial.
# Capture first, then match. `grep -q` closes the pipe early, which hands codesign a
# SIGPIPE -- and under `set -o pipefail` that turns a SUCCESSFUL check into a failed
# pipeline, firing the guard on a correctly signed binary.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$BIN" 2>/dev/null | plutil -p - 2>/dev/null || true)"
if ! printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q "com.apple.security.personal-information.calendars"; then
    echo "FAILED: the calendars entitlement is missing from the signed binary."
    echo "Without it, macOS will silently refuse to ever show a Calendar prompt."
    exit 1
fi

SIGNED_FLAGS="$(codesign -dv "$BIN" 2>&1 || true)"
if ! printf '%s' "$SIGNED_FLAGS" | grep -q "flags=.*runtime"; then
    echo "FAILED: the hardened runtime is not enabled on the signed binary."
    exit 1
fi
echo "    entitlement and hardened runtime asserted"

echo
echo "--- identity ---"
codesign -dv "$BIN" 2>&1 | grep -E "Identifier|Authority|CodeDirectory|TeamIdentifier" || true
echo
echo "--- entitlements (must list personal-information.calendars) ---"
codesign -d --entitlements - --xml "$BIN" 2>/dev/null | plutil -p - 2>/dev/null \
  || codesign -d --entitlements - "$BIN" 2>&1 | tail -5
echo
echo "--- cdhash (changes every build; TCC does NOT pin to it) ---"
codesign -dvvv "$BIN" 2>&1 | grep -i "^CDHash" || true
echo
echo "--- designated requirement: THIS is what the TCC grant is checked against ---"
echo "    Identity-based, so rebuilds keep the grant. The grant is keyed to the"
echo "    binary's ABSOLUTE PATH, so moving or reinstalling it needs a fresh --setup."
codesign -d -r- "$BIN" 2>&1 | grep designated || true
