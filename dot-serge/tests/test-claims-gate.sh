#!/usr/bin/env bash
# Tests for claims-gate.sh — $0, no network except the url cases (skipped here).
# Every assertion is against real filesystem/transcript state built in TMPDIR, so
# the gate is exercised the way it runs in production.
set -uo pipefail
HOOK="${SERGE_CLAIMS_SCRIPT:-$HOME/.serge/claims-gate.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

printf 'hello world\n' > "$T/real.txt"
GOOD=$(sha256sum "$T/real.txt" | cut -c1-64)

# transcript carrying one Bash call and its result
mktx() {
  cat > "$T/tx" <<EOF
{"type":"user","message":{"content":"do the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"w"},{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"bun test"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"$1","is_error":false}]}}
EOF
}
# Same shape as mktx but the turn only READS — no mutation, so the
# unclaimed-success check must not fire. Pins the other half of the hardened
# contract: only turns that actually changed something are taxed.
mktx_readonly() {
  cat > "$T/tx" <<EOF
{"type":"user","message":{"content":"explain the thing"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"w"},{"type":"tool_use","id":"c1","name":"Read","input":{"file_path":"$T/real.txt"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"$1","is_error":false}]}}
EOF
}
run() {
  printf '{"transcript_path":"%s","session_id":"c%s","last_assistant_message":%s}' \
    "$T/tx" "$RANDOM" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | bash "$HOOK"
}
blocks() { local out; out=$(run "$2")
  if printf '%s' "$out" | grep -q "$3"; then ok "$1"
  else bad "$1 — not blocked (out=${out:0:110})"; fi; }
allows() { local out; out=$(run "$2")
  if [ -z "$out" ]; then ok "$1"; else bad "$1 — blocked (out=${out:0:110})"; fi; }

mktx "12 pass, 0 fail"

echo "── claims that match reality ──"
allows "true file hash + true cmd" "Done.
<claims>
file $T/real.txt sha256=$GOOD
cmd \"bun test\" exit=0
</claims>"
allows "file exists (no hash)" "Done.
<claims>
file $T/real.txt exists
</claims>"

echo
echo "── claims that do not ──"
blocks "nonexistent file"      "Done.
<claims>
file $T/ghost.txt exists
</claims>" "does NOT exist"
blocks "wrong sha256"          "Done.
<claims>
file $T/real.txt sha256=deadbeefdeadbeef
</claims>" "actual sha256"
blocks "cmd never run"         "Done.
<claims>
cmd \"pytest -q\" exit=0
</claims>" "never ran it"

mktx "9 pass, 3 fail"
blocks "cmd ran but FAILED"    "Done.
<claims>
cmd \"bun test\" exit=0
</claims>" "shows failures"

echo
echo "── scope: the gate only judges claims that were made ──"
mktx "12 pass, 0 fail"
# HARDENED 2026-08-22: a turn that MUTATED something and asserts success with
# no falsifiable block is nudged once. The old contract — no <claims> block is a
# free pass — was the hole that let "Done, I fixed the parser" ship on a turn
# where nothing changed, which is the failure this gate exists for. A turn that
# changes nothing still passes untaxed, so both halves are pinned here.
blocks  "success claimed after a real edit, no claims block" \
                                     "Done, I fixed the parser." "record"
mktx_readonly "hello world"
allows  "no claims block, and nothing was changed" "Here is how the parser works."
mktx "12 pass, 0 fail"
allows "empty claims block"          "Done.
<claims>
</claims>"
allows "comment-only claims block"   "Done.
<claims>
# nothing asserted yet
</claims>"

echo
echo "── safety ──"
out=$(SERGE_CLAIMS_GATE_DISABLE=1 run "Done.
<claims>
file $T/ghost.txt exists
</claims>")
[ -z "$out" ] && ok "SERGE_CLAIMS_GATE_DISABLE=1 → inert" || bad "off-switch ignored"

out=$(printf '{"bogus":true}' | bash "$HOOK" 2>&1); rc=$?
{ [ "$rc" = "0" ] && [ -z "$out" ]; } && ok "malformed payload → fails open" || bad "malformed payload rc=$rc"

out=$(printf '{"last_assistant_message":"Done.\\n<claims>\\nfile /nope exists\\n</claims>"}' | bash "$HOOK")
printf '%s' "$out" | grep -q "does NOT exist" && ok "works without a transcript (in-band text)" || bad "in-band path broken"

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — claims gate"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
