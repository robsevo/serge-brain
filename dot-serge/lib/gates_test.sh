#!/usr/bin/env bash
# Behavioural tests for arch-gate.sh, plan-gate.sh and design-directive.sh.
#
# Tests the HOOKS, not the scanner (archscan_test.py does that): does the right
# payload shape come out, does it block when it should, and — the part that keeps
# it honest — does it stay quiet when it should.
#
#   ./gates_test.sh              run the matrix
#   ./gates_test.sh --self-test  prove the matrix catches a gate that does nothing
set -uo pipefail

SERGE_DIR="${SERGE_DIR:-$HOME/.serge}"
SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# In self-test mode every gate is replaced by a no-op, and the suite must fail.
run_gate() {
  local gate="$1"
  if [ "$SELF_TEST" = "1" ]; then cat >/dev/null; return 0; fi
  bash "$SERGE_DIR/$gate"
}

check() {  # check <name> <expected: block|quiet|context> <gate> <payload>
  local name="$1" expect="$2" gate="$3" payload="$4"
  local out rc
  out="$(printf '%s' "$payload" | run_gate "$gate" 2>&1)"; rc=$?
  local got="quiet"
  if [ "$rc" = "2" ]; then got="block"
  elif printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got="block"
  elif printf '%s' "$out" | grep -q 'additionalContext'; then got="context"
  fi
  if [ "$got" = "$expect" ]; then
    printf '  ok    %-52s %s\n' "$name" "$expect"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-52s expected %s, got %s\n' "$name" "$expect" "$got"; FAIL=$((FAIL+1))
  fi
}

# ── fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/repo/src" "$TMP/repo/scripts"
echo '{"name":"fixture"}' > "$TMP/repo/package.json"
cat > "$TMP/repo/src/index.js" <<'EOF'
import { good } from './good.js'
export const boot = () => good()
EOF
cat > "$TMP/repo/src/good.js" <<'EOF'
export const good = () => 1
EOF
# A genuinely clean module has a test. Added after untested-behaviour shipped and
# correctly flagged this fixture — the fixture was incomplete, not the check.
cat > "$TMP/repo/src/good.test.js" <<'EOF'
import { good } from './good.js'
it('returns 1', () => { expect(good()).toBe(1) })
EOF
cat > "$TMP/repo/src/bad.js" <<'EOF'
export function h(){ try { risky() } catch (e) {} }
EOF
cat > "$TMP/repo/src/cycle_a.js" <<'EOF'
import { b } from './cycle_b.js'
export const a = () => b()
EOF
cat > "$TMP/repo/src/cycle_b.js" <<'EOF'
import { a } from './cycle_a.js'
export const b = () => a()
EOF

# Unique per run: the gates keep block-once markers in /tmp keyed by session id,
# so without this a second run of the suite would see every gate already relented.
RUN_ID="$(basename "$TMP")"
# The counter lives in a FILE, not a variable: sid() is always called inside
# "$(...)", which is a subshell, so an incremented shell variable is discarded
# the moment it returns and every payload would share one session id.
SEQ_FILE="$TMP/.seq"; echo 0 > "$SEQ_FILE"
sid() {
  local n; n=$(( $(cat "$SEQ_FILE") + 1 )); echo "$n" > "$SEQ_FILE"
  printf '%s-%s' "$RUN_ID" "$n"
}

p_edit() {  # payload for a PostToolUse edit of $1
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Edit','session_id':sys.argv[3],
 'tool_input':{'file_path':sys.argv[1]},'cwd':sys.argv[2]}))" "$1" "$TMP/repo" "$(sid)"
}
p_bash() {  # payload for a PostToolUse Bash command
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Bash','session_id':sys.argv[3],
 'tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))" "$1" "$TMP/repo" "$(sid)"
}
p_plan() {  # payload for a PreToolUse ExitPlanMode with plan text $1
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'ExitPlanMode','session_id':sys.argv[3],
 'tool_input':{'plan':sys.argv[1]},'cwd':sys.argv[2]}))" "$1" "$TMP/repo" "${2:-$(sid)}"
}
p_prompt() {
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'UserPromptSubmit','prompt':sys.argv[1],'cwd':sys.argv[2]}))" \
 "$1" "$TMP/repo"
}

echo "── arch-gate ──────────────────────────────────────────────────────────"
check "blocks on swallowed error"        block arch-gate.sh "$(p_edit "$TMP/repo/src/bad.js")"
check "blocks on dependency cycle"       block arch-gate.sh "$(p_edit "$TMP/repo/src/cycle_a.js")"
check "quiet on clean wired module"      quiet arch-gate.sh "$(p_edit "$TMP/repo/src/good.js")"
check "ignores non-source files"         quiet arch-gate.sh "$(p_edit "$TMP/repo/package.json")"
check "ignores a Bash command that writes nothing" quiet arch-gate.sh "$(p_bash 'ls -la')"
# The bypass that made every code gate optional until 2026-08-22: source written
# through the shell was matched by nothing, so a model denied Write simply used Bash.
check "FOLLOWS a Bash heredoc write"     block arch-gate.sh "$(p_bash 'cat > src/bad.js <<EOF
x
EOF')"
check "FOLLOWS a Bash redirect write"    block arch-gate.sh "$(p_bash "printf 'x' > src/bad.js")"
check "FOLLOWS sed -i"                   block arch-gate.sh "$(p_bash "sed -i 's/a/b/' src/bad.js")"

# LOOP GUARD. A gate that blocks the same finding forever traps the session: the
# model edits, is blocked, edits again, is blocked again, and the turn never ends.
# Blocks once per finding-set; a CHANGED set blocks again (verified separately).
LOOP_SID="$(sid)"
LOOP_PAYLOAD="$(python3 -c "
import json,sys
print(json.dumps({'tool_name':'Write','session_id':sys.argv[1],
 'tool_input':{'file_path':'$TMP/repo/src/bad.js'},'cwd':'$TMP/repo'}))" "$LOOP_SID")"
check "arch-gate blocks the first time"  block arch-gate.sh "$LOOP_PAYLOAD"
check "arch-gate relents the second"     context arch-gate.sh "$LOOP_PAYLOAD"

echo
echo "── plan-gate ──────────────────────────────────────────────────────────"
GOOD_T2='## Plan
Refactor the token refresh in `src/good.js` and `src/index.js`.

1. Move refresh into good.js. Verified by: unit test asserting the token changes.
2. Update the caller in index.js. Verified by: existing suite must stay green.

Considered doing this in a middleware instead, rejected because it would put
auth logic in the transport layer.

This does NOT touch the logout path or the session store.'
check "passes a complete T2 plan"        quiet plan-gate.sh "$(p_plan "$GOOD_T2")"

BAD_FICTION='## Plan
Update `src/services/auth-manager.ts` and `src/lib/token-store.ts` to refresh
tokens. Then update `src/index.js`. Verified by running the tests.
Considered a middleware instead; rejected. Does not touch logout.'
check "blocks a plan citing missing files" block plan-gate.sh "$(p_plan "$BAD_FICTION")"

BAD_NOVERIFY='## Plan
Change `src/good.js` and `src/index.js` and `src/bad.js` and `src/cycle_a.js`.
It will work better afterwards.'
check "blocks a plan with no verification" block plan-gate.sh "$(p_plan "$BAD_NOVERIFY")"

T3_THIN='## Plan
Add a migration to `src/good.js` changing the users schema and auth token column.
Verified by tests. Considered an alternative, rejected. Does not touch billing.'
check "blocks a thin T3 (schema/auth) plan"  block plan-gate.sh "$(p_plan "$T3_THIN")"

# Same plan, same session, twice: first blocks, second must relent to context.
PLAN_SID="$(sid)"
PLAN_LOOP="$(p_plan "$BAD_NOVERIFY" "$PLAN_SID")"
check "plan-gate blocks the first time"   block   plan-gate.sh "$PLAN_LOOP"
check "plan-gate relents the second"      context plan-gate.sh "$PLAN_LOOP"

check "ignores non-plan tools"            quiet plan-gate.sh \
  "$(python3 -c "import json;print(json.dumps({'tool_name':'Write','tool_input':{'file_path':'x'},'cwd':'$TMP/repo'}))")"

echo
echo "── design-directive ───────────────────────────────────────────────────"
check "injects on a build prompt"        context design-directive.sh \
  "$(p_prompt 'Add an HTTP client that fetches user records from the API and caches them')"
check "quiet on a question"              quiet design-directive.sh \
  "$(p_prompt 'What does the loop in good.js do?')"
check "quiet on a typo fix"              quiet design-directive.sh \
  "$(p_prompt 'fix the typo in the readme')"
check "injects on a schema task"         context design-directive.sh \
  "$(p_prompt 'Implement a migration adding an email column to the users table')"
check "enters DIAGNOSIS mode on a bug"   context design-directive.sh \
  "$(p_prompt 'debug why the parser crashes on empty input')"
check "enters REFACTOR mode"             context design-directive.sh \
  "$(p_prompt 'refactor the auth module to remove duplication')"

echo
TOTAL=$((PASS+FAIL))
if [ "$SELF_TEST" = "1" ]; then
  # Every check that expects block/context must fail against no-op gates.
  if [ "$FAIL" -gt 0 ]; then
    echo "  SELF-TEST PASSED — no-op gates failed $FAIL/$TOTAL checks."
    exit 0
  fi
  echo "  SELF-TEST FAILED — gates that do nothing passed every check."
  echo "  This suite does not actually verify the gates."
  exit 1
fi
echo "  $PASS/$TOTAL passed"
[ "$FAIL" = "0" ] || exit 1
