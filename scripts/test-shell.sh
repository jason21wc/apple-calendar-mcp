#!/bin/bash
# Tests for scripts/*.sh. Runs standalone (./scripts/test-shell.sh) and is also driven by
# the Swift suite (Tests/AppleCalendarMCPTests/ShellScriptTests.swift).
#
# WHY THIS FILE EXISTS
# The scripts here establish the machine's code-signing trust anchor and assert that the
# signed binary carries the calendars entitlement. When one of them is wrong the failure is
# not a crash: make-signing-cert.sh issues a SECOND certificate and the TCC grant, whose
# designated requirement names the first certificate's root, stops matching; or sign.sh
# reports a correctly signed binary as broken and a human "fixes" something that was fine.
#
# The headline regression is gotcha 34. Under `set -o pipefail`, `cmd | grep -q PATTERN`
# reports FAILURE when the pattern matches: grep -q exits the moment it matches, the pipe
# closes, the still-running upstream takes SIGPIPE and exits 141, and pipefail promotes that
# to the pipeline's status. So `if ! cmd | grep -q X` fires on a SUCCESSFUL match. It cost an
# assertion in sign.sh once already.
#
# This file deliberately uses `<<<` here-strings and `case` rather than pipelines for its own
# matching, and check 9 lints this file along with the others.

set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
SCRIPT_DIR="$REPO_ROOT/scripts"

PASS=0
FAIL=0
WARN=0
FAILURES=""
WARNINGS=""

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
    printf '        %s\n' "$2"
    FAILURES="$FAILURES
  - $1
      $2"
}
warn() {
    WARN=$((WARN + 1))
    printf '  warn  %s\n' "$1"
    printf '        %s\n' "$2"
    WARNINGS="$WARNINGS
  - $1
      $2"
}
section() { printf '\n== %s\n' "$1"; }

# All scripts under test, including this one.
SCRIPTS=""
for f in "$SCRIPT_DIR"/*.sh; do
    [ -f "$f" ] && SCRIPTS="$SCRIPTS $f"
done
[ -n "$SCRIPTS" ] || { echo "no scripts found in $SCRIPT_DIR"; exit 1; }

# Checks 6, 7 and 9 are about the signing scripts. This file is excluded from them because
# it necessarily CONTAINS the strings it searches for -- linting a linter's own patterns
# produces findings about the linter, not about the code under test. It is NOT excluded from
# checks 2 to 5, which it must satisfy like anything else.
SIGNING_SCRIPTS=""
for f in $SCRIPTS; do
    case "$(basename "$f")" in
        test-shell.sh) ;;
        *) SIGNING_SCRIPTS="$SIGNING_SCRIPTS $f" ;;
    esac
done

# Strip comments and blank lines so the linters below look at code, not at prose. These
# scripts carry long explanatory comments that mention the very patterns being linted.
code_of() {
    sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//' "$1"
}

# ---------------------------------------------------------------------------------------
section "1. the SIGPIPE trap this suite exists to catch is still real on this platform"
# ---------------------------------------------------------------------------------------
# A characterisation test of bash + macOS, not of our code. If it ever stops holding, every
# lint below is obsolete and should be deleted rather than left to rot.
#
# The producer emits a matching line, then keeps running. That is the shape of every real
# case: `security find-identity` and `codesign` are both still working after their first
# line of output. Total output is a few bytes, so this is NOT about the 64 KiB pipe buffer --
# it is a race the upstream loses whenever it outlives the downstream.
sigpipe_probe() {
    set -o pipefail
    producer() { echo "NEEDLE"; sleep 0.3; echo "trailing"; }
    if producer | grep -q "NEEDLE"; then echo "match"; else echo "inverted:${PIPESTATUS[0]}"; fi  # lint-ok: this IS the demonstration
}
PROBE_RESULT="$(sigpipe_probe)"
case "$PROBE_RESULT" in
    inverted:141)
        pass "pipefail + early-exiting downstream still inverts a passing check (upstream exit 141)"
        ;;
    match)
        warn "the pipefail/SIGPIPE inversion no longer reproduces on this platform" \
             "bash $BASH_VERSION no longer propagates it; re-evaluate checks 5 and 6 before trusting them"
        ;;
    *)
        warn "SIGPIPE probe produced an unexpected result: $PROBE_RESULT" \
             "the platform behaviour behind checks 5 and 6 could not be confirmed"
        ;;
esac

# The buffered variant: even a producer that exits promptly loses the race once its output
# exceeds the pipe buffer. This is what makes `printf '%s' "$VAR" | grep -q` a mitigation
# rather than a fix.
bigpipe_probe() {
    set -o pipefail
    BIG="$(awk 'BEGIN { for (i = 0; i < 200000; i++) print "NEEDLE " i }')"
    if printf '%s' "$BIG" | grep -q "NEEDLE"; then echo "match"; else echo "inverted:${PIPESTATUS[0]}"; fi  # lint-ok: this IS the demonstration
}
BIG_RESULT="$(bigpipe_probe)"
case "$BIG_RESULT" in
    inverted:141)
        pass "capture-then-printf into grep -q also inverts once output exceeds the pipe buffer"
        ;;
    match)
        warn "printf-into-grep -q did not invert at 200k lines" \
             "the 64 KiB threshold may have moved; check 5's WARN tier may be over-cautious"
        ;;
esac

# ---------------------------------------------------------------------------------------
section "2. every script parses"
# ---------------------------------------------------------------------------------------
for f in $SCRIPTS; do
    name="$(basename "$f")"
    if ERR="$(bash -n "$f" 2>&1)"; then
        pass "bash -n $name"
    else
        fail "bash -n $name" "$ERR"
    fi
done

# ---------------------------------------------------------------------------------------
section "3. every script is launchable"
# ---------------------------------------------------------------------------------------
for f in $SCRIPTS; do
    name="$(basename "$f")"
    FIRST_LINE="$(head -n 1 "$f")"
    case "$FIRST_LINE" in
        '#!'*bash|'#!'*bash*) pass "$name has a bash shebang" ;;
        '#!'*) fail "$name shebang is not bash" "found: $FIRST_LINE (these scripts use bash-only syntax such as PIPESTATUS and <<<)" ;;
        *)     fail "$name has no shebang" "first line: $FIRST_LINE" ;;
    esac
    if [ -x "$f" ]; then
        pass "$name is executable"
    else
        fail "$name is not executable" "README tells users to run ./scripts/$name directly"
    fi
done

# ---------------------------------------------------------------------------------------
section "4. error handling is switched on, or its absence is deliberate and stated"
# ---------------------------------------------------------------------------------------
for f in $SCRIPTS; do
    name="$(basename "$f")"
    CONTENT="$(cat "$f")"

    case "$CONTENT" in
        *"set -"*"o pipefail"*|*"set -"*"pipefail"*) pass "$name enables pipefail" ;;
        *) fail "$name does not enable pipefail" "a failing stage in the middle of a pipeline would be invisible" ;;
    esac

    case "$CONTENT" in
        *"set -e"*|*"set -eu"*|*"set -euo"*)
            pass "$name enables errexit" ;;
        *)
            # trust-signing-cert.sh omits -e on purpose: its `|| echo` fallbacks ARE the error
            # handling and -e would abort before they run. That is fine, but it has to be said
            # out loud so nobody removes -e from another script by accident.
            case "$CONTENT" in
                *"deliberately omitted"*|*"Do not \"fix\" this"*)
                    pass "$name omits errexit, and says so deliberately" ;;
                *)
                    fail "$name omits errexit with no explanation" \
                         "either add 'set -e' or state in a comment why it is deliberately omitted" ;;
            esac
            ;;
    esac
done

# ---------------------------------------------------------------------------------------
section "5. gotcha 34: no pipeline whose status is consumed can be inverted by SIGPIPE"
# ---------------------------------------------------------------------------------------
# Downstream commands that exit before reading their input: grep -q, head, and `read`.
# The upstream then takes SIGPIPE and pipefail turns a passing check into a failing one.
#
# ERROR when the upstream is an external command: it is still running when the downstream
#       exits, so the inversion is a near-certainty rather than a size-dependent race.
# WARN  when the upstream is printf or echo of an already-captured variable: that is the fix
#       recorded in gotcha 34, and it is safe only while the data stays under the pipe
#       buffer -- probe 1 above demonstrates it failing at 200k lines.
for f in $SCRIPTS; do
    name="$(basename "$f")"
    CODE="$(code_of "$f")"
    HITS="$(printf '%s\n' "$CODE" | grep -n -E '\|[[:space:]]*(grep[[:space:]]+-[a-zA-Z]*q|head([[:space:]]|$)|read[[:space:]])' || true)"

    if [ -z "$HITS" ]; then
        pass "$name has no early-exiting pipeline stage"
        continue
    fi

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        LINENO_HIT="${hit%%:*}"
        TEXT="${hit#*:}"

        # `|| true`, `|| :` and `|| <fallback>` all discard the pipeline's status.
        case "$TEXT" in
            *"|| true"*|*"|| :"*|*"||"*) pass "$name:$LINENO_HIT early-exiting stage, status discarded" ; continue ;;
        esac

        # An explicit opt-out, for lines that exist in order to demonstrate the bug.
        RAW_LINE="$(sed -n "${LINENO_HIT}p" "$f")"
        case "$RAW_LINE" in
            *"lint-ok:"*) pass "$name:$LINENO_HIT early-exiting stage, marked lint-ok"; continue ;;
        esac

        # Everything left of the last pipe is the upstream. `sed -E`, not plain sed: BSD sed
        # does not understand \| alternation in a basic regular expression, and silently
        # matches nothing instead of erroring -- which classified every hit as external.
        UPSTREAM="${TEXT%|*}"
        UPSTREAM="$(printf '%s' "$UPSTREAM" | sed -E -e 's/^[[:space:]]*//' -e 's/^(if|elif|while|until)[[:space:]]+//' -e 's/^![[:space:]]*//' -e 's/^[[:space:]]*//')"

        case "$UPSTREAM" in
            printf*|echo*)
                warn "$name:$LINENO_HIT capture-then-printf into an early-exiting stage" \
                     "safe only below the 64 KiB pipe buffer (probe 1 shows it failing above it); prefer: grep -q PATTERN <<<\"\$VAR\"  or  case \"\$VAR\" in *PATTERN*)"
                ;;
            *)
                fail "$name:$LINENO_HIT external command piped into an early-exiting stage under pipefail" \
                     "gotcha 34: the upstream outlives the downstream, takes SIGPIPE (141), and pipefail inverts the check. Line: $(printf '%s' "$TEXT" | sed 's/^[[:space:]]*//')"
                ;;
        esac
    done <<EOF
$HITS
EOF
done

# ---------------------------------------------------------------------------------------
section "5b. the identity guard in make-signing-cert.sh, executed against a stub"
# ---------------------------------------------------------------------------------------
# Check 5 is a lint and could in principle be wrong about a particular line. This runs the
# ACTUAL condition, lifted verbatim out of make-signing-cert.sh, against a stub `security`
# that behaves the way the real one does: it prints a matching identity and is still working
# afterwards. Correct behaviour is "present". "absent" means the script would go on to mint a
# SECOND signing certificate -- and the TCC grant's designated requirement names the FIRST
# certificate's root, so the Calendar grant stops matching and access is lost silently
# (gotchas 26 and 34 together).
#
# No keychain is touched: the stub is an ordinary script in a temporary directory, reached
# only through a PATH scoped to one subshell.
GUARD_SRC="$SCRIPT_DIR/make-signing-cert.sh"
GUARD_HITS="$(grep -n 'find-identity.*|.*grep -q' "$GUARD_SRC" || true)"

if [ -z "$GUARD_HITS" ]; then
    pass "make-signing-cert.sh no longer pipes find-identity into grep -q"
else
    GUARD_FIRST="${GUARD_HITS%%
*}"
    GUARD_TEXT="${GUARD_FIRST#*:}"
    GUARD_COND="${GUARD_TEXT#*if }"
    GUARD_COND="${GUARD_COND%%; then*}"

    if [ "$GUARD_COND" = "$GUARD_TEXT" ]; then
        warn "could not lift the identity guard out of make-signing-cert.sh" \
             "the line no longer looks like 'if <pipeline>; then'; check 5b asserted nothing"
    else
        STUB_DIR="$(mktemp -d)"
        cat > "$STUB_DIR/security" <<'STUB'
#!/bin/bash
# Stands in for /usr/bin/security. Prints a matching identity, then keeps working -- which
# is what a real keychain query does, and is the entire cause of the SIGPIPE inversion.
echo '  1) 0000000000000000000000000000000000000000 "apple-calendar-mcp local signing"'
sleep 0.3
echo '     1 valid identities found'
STUB
        chmod +x "$STUB_DIR/security"

        GUARD_RESULT="$(
            PATH="$STUB_DIR:/usr/bin:/bin" \
            CERT_NAME="apple-calendar-mcp local signing" \
            bash -c "set -euo pipefail; if $GUARD_COND; then echo present; else echo absent; fi" 2>&1
        )"
        rm -rf "$STUB_DIR"

        case "$GUARD_RESULT" in
            present)
                pass "make-signing-cert.sh detects an existing identity even when the query outlives grep" ;;
            absent)
                fail "make-signing-cert.sh does NOT detect an existing identity" \
                     "the guard lifted from line ${GUARD_FIRST%%:*} answered 'absent' for an identity that IS present. It would mint a second certificate; the existing TCC grant names the first certificate's root and would stop matching. Fix: IDS=\"\$(security find-identity -v -p codesigning 2>/dev/null || true)\"; then match with case or <<<." ;;
            *)
                warn "the lifted guard produced neither present nor absent" "$GUARD_RESULT" ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------------------
section "6. gotcha 31: set-key-partition-list is always scoped to our own key"
# ---------------------------------------------------------------------------------------
# Unscoped, `-s` matches EVERY sign-capable key in the login keychain, and the command
# REPLACES a partition list rather than appending -- silently breaking other applications'
# access to their own signing keys and granting codesign promptless access to keys that have
# nothing to do with this project. This is a check on blast radius, not on our own outcome.
FOUND_PARTITION=0
for f in $SIGNING_SCRIPTS; do
    name="$(basename "$f")"
    CODE="$(code_of "$f")"
    case "$CODE" in
        *set-key-partition-list*)
            FOUND_PARTITION=1
            case "$CODE" in
                *set-key-partition-list*-l\ *|*"-l \"\$CERT_NAME\""*)
                    pass "$name scopes set-key-partition-list with -l" ;;
                *)
                    fail "$name calls set-key-partition-list without -l" \
                         "unscoped, it rewrites the partition list of every signing key in the login keychain" ;;
            esac
            ;;
    esac
done
[ "$FOUND_PARTITION" -eq 1 ] || warn "no script calls set-key-partition-list" \
    "check 6 asserted nothing; if the call was removed, delete this check"

# ---------------------------------------------------------------------------------------
section "7. PATH is pinned before any signing or keychain tool is invoked"
# ---------------------------------------------------------------------------------------
# These scripts create and use the machine's code-signing trust anchor. npm, homebrew and
# conda all put user-writable directories ahead of /usr/bin on a developer machine, so a
# shimmed `codesign` or `security` would own the operation outright.
for f in $SIGNING_SCRIPTS; do
    name="$(basename "$f")"
    CODE="$(code_of "$f")"
    FIRST_TOOL="$(printf '%s\n' "$CODE" | grep -n -E '(^|[^-[:alnum:]_/])(codesign|security|installer)([[:space:]]|$)' | sed -n '1s/:.*//p' || true)"
    [ -n "$FIRST_TOOL" ] || { pass "$name invokes no signing or keychain tool"; continue; }

    FIRST_PIN="$(printf '%s\n' "$CODE" | grep -n -E '^[[:space:]]*PATH=' | sed -n '1s/:.*//p' || true)"
    if [ -z "$FIRST_PIN" ]; then
        fail "$name does not pin PATH" "it invokes a signing or keychain tool at line $FIRST_TOOL with an inherited PATH"
    elif [ "$FIRST_PIN" -lt "$FIRST_TOOL" ]; then
        pass "$name pins PATH (line $FIRST_PIN) before its first tool call (line $FIRST_TOOL)"
    else
        fail "$name pins PATH too late" "PATH is set at line $FIRST_PIN but a tool runs at line $FIRST_TOOL"
    fi
done

# ---------------------------------------------------------------------------------------
section "8. gotcha 32: nothing recommends a tccutil reset that cannot work"
# ---------------------------------------------------------------------------------------
# Our TCC row is client_type=1 (absolute path). tccutil accepts bundle identifiers only and
# fails with 'No such bundle identifier' (OSStatus -10814). This advice shipped once.
TCC_SEARCH="$SCRIPT_DIR $REPO_ROOT/Sources"
for extra in "$REPO_ROOT/README.md" "$REPO_ROOT/docs"; do
    [ -e "$extra" ] && TCC_SEARCH="$TCC_SEARCH $extra"
done
# `tccutil reset`, not bare "tccutil": prose that merely names the tool is not advice to run
# a command, and flagging it would train people to ignore this check.
TCC_FILES="$(grep -rl "tccutil reset" $TCC_SEARCH 2>/dev/null || true)"
if [ -z "$TCC_FILES" ]; then
    pass "nothing in scripts, sources or docs spells out a tccutil reset command"
else
    while IFS= read -r tf; do
        [ -n "$tf" ] || continue
        rel="${tf#$REPO_ROOT/}"
        CONTENT="$(cat "$tf")"
        case "$CONTENT" in
            *"does NOT work"*|*"cannot"*|*"does not work"*)
                pass "$rel mentions tccutil only alongside an explicit warning" ;;
            *)
                fail "$rel names tccutil without saying it cannot work here" \
                     "tccutil reset Calendar <bundle-id> fails with OSStatus -10814 against a path-keyed row" ;;
        esac
    done <<EOF
$TCC_FILES
EOF
fi

# ---------------------------------------------------------------------------------------
section "9. secrets do not travel through argv where every same-uid process can read them"
# ---------------------------------------------------------------------------------------
# `ps auxww` and sysctl kern.procargs2 expose an argument vector to any process running as
# this user. make-signing-cert.sh uses -passout fd:3 for exactly this reason; the one
# accepted exception is `security import -P`, which offers no alternative and is documented
# in place.
for f in $SIGNING_SCRIPTS; do
    name="$(basename "$f")"
    CODE="$(code_of "$f")"
    case "$CODE" in
        *"-passin pass:"*|*"-passout pass:"*|*"-password "*)
            fail "$name passes a secret on the command line" \
                 "use -passin/-passout fd:N, or let the tool prompt" ;;
        *)
            pass "$name keeps openssl passphrases out of argv" ;;
    esac
    case "$CODE" in
        *"set-key-partition-list"*"-k "*)
            fail "$name passes the login keychain password in argv" \
                 "omit -k and let security prompt on its own tty" ;;
    esac
done

# ---------------------------------------------------------------------------------------
printf '\n===========================================================================\n'
printf 'pass: %s   warn: %s   FAIL: %s\n' "$PASS" "$WARN" "$FAIL"
if [ -n "$WARNINGS" ]; then
    printf '\nWarnings (latent, not currently firing):%s\n' "$WARNINGS"
fi
if [ "$FAIL" -gt 0 ]; then
    printf '\nFailures:%s\n' "$FAILURES"
    printf '\nThese are defects in scripts/, not in the tests.\n'
    exit 1
fi
printf '\nAll shell checks passed.\n'
exit 0
