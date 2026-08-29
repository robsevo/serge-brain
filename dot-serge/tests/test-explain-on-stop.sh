#!/usr/bin/env bash
# Tests for explain-on-stop.sh — $0, no network, no LLM.
#
# The gate has to be narrow or it is worse than nothing, so most of these assert
# that it stays QUIET: on a turn that wrote nothing, on a turn that explained
# itself, on an interrupted turn, and on the second pass after it already fired.
# Only two cases block.
set -uo pipefail
HOOK="${SERGE_EXPLAIN_SCRIPT:-$HOME/.serge/explain-on-stop.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

[ -x "$HOOK" ] || { echo "no hook at $HOOK (set SERGE_EXPLAIN_SCRIPT)"; exit 1; }

LONG="I rewrote the session lister so it stats every transcript first and only \
reads the twenty it is going to return, instead of reading and parsing all of \
them and then throwing most away. Same rows, same order; the cost stops \
tracking how much history the directory holds. I also deleted a dead local the \
checker flagged. Tests added for both."

# A transcript: one real user prompt, then whatever tool_use block is asked for.
mktx() {                       # mktx <file> <toolname|-> [file_path]
  local out="$1" tool="$2" fp="${3:-/tmp/x.ts}"
  {
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the route"}]}}'
    if [ "$tool" != "-" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"c1","name":"%s","input":{"file_path":"%s"}}]}}\n' "$tool" "$fp"
      echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c1","content":"ok","is_error":false}]}}'
    fi
  } > "$out"
}

# payload <transcript> <final message> [extra json] -> writes $T/payload
payload() {
  python3 -c '
import json, sys
d = {"hook_event_name": "Stop", "transcript_path": sys.argv[1],
     "last_assistant_message": sys.argv[2], "session_id": "s", "cwd": "/tmp"}
if sys.argv[3]:
    d.update(json.loads(sys.argv[3]))
print(json.dumps(d))
' "$1" "$2" "${3:-}" > "$T/payload"
}

# run … -> prints the HOOK's exit status.
#
# The payload goes through a FILE, not a pipe. A hook is entitled to exit before
# reading stdin — the off-switch does exactly that, and so does every other brain
# hook — which kills a piped writer with SIGPIPE; under `pipefail` that made the
# pipeline status non-zero and an earlier version of this test read it as the
# hook blocking. The harness's own dispatcher wraps its stdin write in a
# try/catch for the same reason ("the hook may not read stdin").
run() {
  payload "$1" "$2" "${3:-}"
  "$HOOK" < "$T/payload" > /dev/null 2>"$T/err"
  echo $?
}

# ── it blocks the case that started this ─────────────────────────────────────
mktx "$T/edited" Edit "/repo/app/api/events/route.ts"
[ "$(run "$T/edited" "Done.")" = "2" ] \
  && ok "an edit-bearing turn ending in 'Done.' is blocked" \
  || bad "an edit-bearing turn ending in 'Done.' is blocked"
grep -q "route.ts" "$T/err" \
  && ok "the block names the file that was changed" \
  || bad "the block names the file that was changed ($(head -c 120 "$T/err"))"
grep -qi "do not redo the work" "$T/err" \
  && ok "and tells it to describe, not repeat, the work" \
  || bad "and tells it to describe, not repeat, the work"

[ "$(run "$T/edited" "")" = "2" ] \
  && ok "an empty final message is blocked" \
  || bad "an empty final message is blocked"

mktx "$T/wrote" Write "/repo/src/new.ts"
[ "$(run "$T/wrote" "ok")" = "2" ] \
  && ok "Write counts as changing a file" \
  || bad "Write counts as changing a file"

# ── and stays quiet everywhere else ──────────────────────────────────────────
[ "$(run "$T/edited" "$LONG")" = "0" ] \
  && ok "a real summary passes" \
  || bad "a real summary passes ($(head -c 120 "$T/err"))"

mktx "$T/readonly" -
[ "$(run "$T/readonly" "Done.")" = "0" ] \
  && ok "a turn that wrote nothing is left alone" \
  || bad "a turn that wrote nothing is left alone"

mktx "$T/bash" Bash
[ "$(run "$T/bash" "Done.")" = "0" ] \
  && ok "a turn that only ran commands is left alone" \
  || bad "a turn that only ran commands is left alone"

[ "$(run "$T/edited" "Done." '{"stop_hook_active":true}')" = "0" ] \
  && ok "it blocks at most once per turn" \
  || bad "it blocks at most once per turn"

[ "$(run "$T/edited" "[Request interrupted by user]")" = "0" ] \
  && ok "an interrupted turn is not nagged" \
  || bad "an interrupted turn is not nagged"

[ "$(run "$T/edited" "[Request interrupted by user for tool use]")" = "0" ] \
  && ok "including the tool-use interrupt" \
  || bad "including the tool-use interrupt"

# An edit in an EARLIER turn is not this turn's business.
{
  cat "$T/edited"
  echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"now just tell me about it"}]}}'
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"sure"}]}}'
} > "$T/prevturn"
[ "$(run "$T/prevturn" "Done.")" = "0" ] \
  && ok "an edit from a PREVIOUS turn does not count" \
  || bad "an edit from a PREVIOUS turn does not count"

# ── fails open ───────────────────────────────────────────────────────────────
[ "$(run "$T/nope" "Done.")" = "0" ] \
  && ok "a missing transcript fails open" \
  || bad "a missing transcript fails open"

echo '{"type":"user","message":' > "$T/broken"
[ "$(run "$T/broken" "Done.")" = "0" ] \
  && ok "an unparseable transcript fails open" \
  || bad "an unparseable transcript fails open"

printf 'not json at all\n' > "$T/payload"
"$HOOK" < "$T/payload" >/dev/null 2>&1 \
  && ok "garbage on stdin fails open" \
  || bad "garbage on stdin fails open"

printf '{"hook_event_name":"PreToolUse"}\n' > "$T/payload"
"$HOOK" < "$T/payload" >/dev/null 2>&1 \
  && ok "another event is ignored" \
  || bad "another event is ignored"

export SERGE_EXPLAIN_DISABLE=1
[ "$(run "$T/edited" "Done.")" = "0" ] \
  && ok "the off-switch works" \
  || bad "the off-switch works"
unset SERGE_EXPLAIN_DISABLE

# ── the knobs ────────────────────────────────────────────────────────────────
export SERGE_EXPLAIN_MIN_CHARS=10
[ "$(run "$T/edited" "Rewrote the route handler.")" = "0" ] \
  && ok "a lower bar accepts a shorter summary" \
  || bad "a lower bar accepts a shorter summary"
unset SERGE_EXPLAIN_MIN_CHARS

export SERGE_EXPLAIN_REQUIRE_FILES=1
[ "$(run "$T/edited" "$LONG")" = "2" ] \
  && ok "opt-in: a summary naming no file is blocked" \
  || bad "opt-in: a summary naming no file is blocked"
[ "$(run "$T/edited" "$LONG I did all of that in route.ts.")" = "0" ] \
  && ok "opt-in: naming the file passes" \
  || bad "opt-in: naming the file passes ($(head -c 120 "$T/err"))"
unset SERGE_EXPLAIN_REQUIRE_FILES

echo
echo "  $pass passed, $fail failed"
[ "$fail" = "0" ]
