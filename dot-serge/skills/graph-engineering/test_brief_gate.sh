#!/usr/bin/env bash
# Tests for ~/.serge/subagent-brief-gate.sh
# Run: bash ~/.serge/skills/graph-engineering/test_brief_gate.sh
#
# Uses the SAME seeded repos as evals/graph-behavior/ (b1 = RAM ceiling in DEPLOY.md,
# b2 = jest banned in CONTRIBUTING.md), because those are the two omissions that were
# actually measured, not hypothetical ones.
#
# The gate must ATTACH only when: change-brief + repo has hard constraints + brief mentions
# none of their tokens. Everything else passes untouched. A false attach puts noise in a
# brief, so the pass-through cases below matter as much as the positive ones.
set -uo pipefail

GATE="${HOME}/.serge/subagent-brief-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE not executable"; exit 1; }

TRUE_HOME="$HOME"
WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
pass=0; fail=0

# Keep TMPDIR inside this run's dir so nothing leaks into /tmp. (v1 wrote block-once
# markers there and the suite was non-idempotent as a result; the attach design has no
# markers, but the isolation is still the right default.)
export TMPDIR="$WS/marks"; mkdir -p "$TMPDIR"

# --- b1 repo: RAM ceiling in DEPLOY.md --------------------------------------
mkdir -p "$WS/b1"
cat > "$WS/b1/DEPLOY.md" <<'EOF'
# Deploy notes

## The box

Everything runs on ONE self-hosted box (2 vCPU). It is small and it is already tight:

- Total RAM is 2 GB. At evening peak there is only about 512 MB actually free.
- Because of the above, **any new long-running process we add must stay under 128 MB RSS.**
  We have OOM-killed the API twice this year by ignoring this.
EOF

# --- b2 repo: jest banned, wrapped across lines -----------------------------
mkdir -p "$WS/b2"
cat > "$WS/b2/CONTRIBUTING.md" <<'EOF'
# Contributing

## Testing

All tests in this repo run on **Vitest**. We removed Jest in PR #412 because the two
runners fought over the same globals and the suite went red at random. CI now fails
the build if `jest` appears anywhere in `package.json` or in an import. Do not add it
back, and do not write tests in Jest syntax expecting a shim — there isn't one.
EOF

# --- clean repo: no constraint docs -----------------------------------------
mkdir -p "$WS/clean"
printf '# thing\n\nA small library. Run npm test.\n' > "$WS/clean/README.md"

call() { # call <cwd> <prompt> [tool] [session]
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'PreToolUse','tool_name':sys.argv[3],
                  'cwd':sys.argv[1],'session_id':sys.argv[4],
                  'tool_input':{'prompt':sys.argv[2],'subagent_type':'backend'}}))
" "$1" "$2" "${3:-Agent}" "${4:-s1}" | "$GATE"
}

t() { # t <ATTACH|passthru> <label> <cwd> <prompt> [tool] [session]
  local want="$1" label="$2" out got
  out=$(call "$3" "$4" "${5:-Agent}" "${6:-s1}")
  if printf '%s' "$out" | grep -q 'Repo constraints (auto-attached'; then got="ATTACH"; else got="passthru"; fi
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  ok    [%s] %s\n' "$got" "$label"
  else fail=$((fail+1)); printf '  FAIL  expected=%s got=%s :: %s\n' "$want" "$got" "$label"; fi
}

CHANGE_B1="Implement a Redis-backed rate limiter for the orders API. Create lib/redisClient.ts that manages the connection, and lib/rateLimitHelper.ts exposing an atomic isRateLimited(key, limit, windowSec) function using a Lua script for the check-and-increment. Wire it into the existing Express app. Return the list of files you created."
AWARE_B1="$CHANGE_B1 The deploy box is tight: any new long-running process must stay under 128 MB RSS, so configure Redis maxmemory accordingly."
CHANGE_B2="Add CSV export to the report generator. Write the exporter in src/csv.ts, then add tests covering the header row, quoting, and empty input. Use the repo's existing test setup and follow the existing style."
AWARE_B2="$CHANGE_B2 Tests must be written for Vitest — jest is banned in this repo and CI fails the build if it appears."
DISCOVERY="Map every call site of resolveStream() across this repository. Read the files, list each call site with its file and line number, and report what arguments each one passes. Do not change any code."

echo "== should ATTACH — change brief omits the repo's hard constraint =="
t ATTACH  "b1: redis brief, no mention of the 128 MB ceiling" "$WS/b1" "$CHANGE_B1" Agent s1
t ATTACH  "b2: csv brief, no mention of vitest/jest ban"      "$WS/b2" "$CHANGE_B2" Agent s2
t ATTACH  "b1 via legacy Task tool name"                      "$WS/b1" "$CHANGE_B1" Task  s3

echo "== should PASS THROUGH — the constraint already crossed the boundary =="
t passthru "b1: brief names the 128 MB ceiling" "$WS/b1" "$AWARE_B1" Agent s4
t passthru "b2: brief names vitest + jest ban"  "$WS/b2" "$AWARE_B2" Agent s5

echo "== should PASS THROUGH — out of scope =="
t passthru "discovery brief (no code change asked)" "$WS/b1" "$DISCOVERY"  Agent s6
t passthru "repo with no constraint docs"           "$WS/clean" "$CHANGE_B1" Agent s7
t passthru "short brief"                            "$WS/b1" "Fix the typo in the header." Agent s8
t passthru "non-spawn tool (Bash)"                  "$WS/b1" "$CHANGE_B1" Bash  s9

echo "== idempotent: an already-attached brief is never double-attached =="
out1=$(call "$WS/b1" "$CHANGE_B1" Agent repeat-sess)
brief2=$(printf '%s' "$out1" | python3 -c "import sys,json;print(json.load(sys.stdin)['hookSpecificOutput']['updatedInput']['prompt'])")
out2=$(call "$WS/b1" "$brief2" Agent repeat-sess)
if printf '%s' "$out1" | grep -q '"updatedInput"' && ! printf '%s' "$out2" | grep -q '"updatedInput"'; then
  pass=$((pass+1)); echo "  ok    [ATTACH then passthru] re-submitting the attached brief does not stack"
else
  fail=$((fail+1)); echo "  FAIL  attachment stacked or first attach missing"
fi

echo "== the constraint must land IN THE BRIEF the subagent will receive =="
r=$(call "$WS/b1" "$CHANGE_B1" Agent quote-sess | python3 -c "import sys,json;print(json.load(sys.stdin)['hookSpecificOutput']['updatedInput']['prompt'])" 2>/dev/null)
if printf '%s' "$r" | grep -q '128 MB' && printf '%s' "$r" | grep -q 'DEPLOY.md:' && printf '%s' "$r" | grep -q "$CHANGE_B1"; then
  pass=$((pass+1)); echo "  ok    [in-brief] updated prompt keeps the original AND adds '128 MB' + DEPLOY.md:line"
else
  fail=$((fail+1)); echo "  FAIL  constraint did not land in the updated brief"
fi
r2=$(call "$WS/b2" "$CHANGE_B2" Agent quote2 | python3 -c "import sys,json;print(json.load(sys.stdin)['hookSpecificOutput']['updatedInput']['prompt'])" 2>/dev/null)
if printf '%s' "$r2" | grep -qi 'jest' && printf '%s' "$r2" | grep -q 'CONTRIBUTING.md:'; then
  pass=$((pass+1)); echo "  ok    [quotes] wrapped-across-lines constraint extracted from CONTRIBUTING.md"
else
  fail=$((fail+1)); echo "  FAIL  wrapped sentence not extracted"
fi

echo "== memory attachment (independent of repo constraints) =="
# The gate needs >=5 memory notes to score relevance at all. A privacy-USB install ships
# memory/MEMORY.md as a header ONLY (no facts, by design), so this section is not
# applicable there — skip rather than fail, and say so.
# NB: `grep -c` exits 1 when the count is 0, so `... || echo 0` would append a SECOND
# line and break the -lt comparison. Count with find instead.
MEMN=$(find "$TRUE_HOME/.serge/memory" -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l)
if [ "${MEMN:-0}" -lt 5 ]; then
  echo "  skip  no memory corpus in this install ($MEMN notes) — memory attach not applicable"
else
memcheck() { # memcheck <want:MEM|none> <label> <prompt>
  local want="$1" label="$2" out got
  out=$(call "$WS/clean" "$3" Agent "mem-$RANDOM")
  if printf '%s' "$out" | grep -q 'Prior lessons (auto-attached'; then got="MEM"; else got="none"; fi
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf '  ok    [%s] %s\n' "$got" "$label"
  else fail=$((fail+1)); printf '  FAIL  expected=%s got=%s :: %s\n' "$want" "$got" "$label"; fi
}
# The probe is DERIVED from a memory this install actually has (mem_probe.py),
# not hardcoded. The old prompt named "example-web" — a project that exists only
# in the public brain's de-identified corpus — so on an install whose memories
# use real names it overlapped nothing, and this check failed while the gate was
# working correctly. Deriving it makes the probe match by construction in either
# world, and it still fails honestly if the scorer breaks.
MEM_PROBE="$(python3 "$(dirname "$0")/mem_probe.py" "$TRUE_HOME/.serge/memory" 2>/dev/null)"
if [ -z "$MEM_PROBE" ]; then
  echo "  skip  could not derive a probe from the memory corpus"
else
  memcheck MEM  "relevant brief pulls serge memory into the subagent's world" \
    "Investigate and fix the following: $MEM_PROBE"
fi
memcheck none "unrelated UI brief attaches no memory" \
  "Add a tooltip component to the design system with hover and focus states, matching the existing button component styling conventions."
memcheck none "unrelated algorithm brief attaches no memory" \
  "Write a function that computes the median of a list of integers and add a couple of unit cases for empty and single-element input."
fi

echo "== brief classifier (change vs discovery) =="
python3 - <<'PYC'
import re, sys, os
src = open(os.path.expanduser("~/.serge/subagent-brief-gate.sh")).read()
ns = {'re': re, 'log': lambda **k: None, 'sys': sys, 'os': os}
exec(src[src.index('NO_CHANGE = re.compile'):src.index('is_discovery = bool(')], ns)
NO_CHANGE, CHANGEV, DISCOVERV = ns['NO_CHANGE'], ns['CHANGEV'], ns['DISCOVERV']
def v(b):
    return "skip" if (NO_CHANGE.search(b) or (DISCOVERV.search(b) and not CHANGEV.search(b))) else "attach"
cases = [
  # Scoped self-limiting change briefs: "without changing any OTHER file" is NOT discovery.
  # These regressed to 0/6 in an eval round when NO_CHANGE matched them.
  ("attach", "Implement a Redis-backed rate limiter in lib/api.ts. Write the list of constraints you were given to received.md first, then stop without changing any other file."),
  ("attach", "Add the CSV exporter to src/report.ts and then stop without modifying anything else in the repository."),
  # Verbs a whitelist would miss.
  ("attach", "Append a single line reading hello to note.txt, keeping the existing formatting, then return the diff you produced."),
  ("attach", "Migrate the config loader to the new schema and update every import site accordingly across the repo."),
  ("attach", "Refactor the retry helper so the backoff is bounded, preserving the public signature, and summarise what changed."),
  # Genuine discovery — must stay exempt so briefs don't get padded.
  ("skip", "Map every call site of resolveStream() across this repository. Report file and line for each. Do not change any code."),
  ("skip", "Investigate why the evening deploys are slow, identify the likely cause, and report your findings. Do not modify anything."),
  # "plan the migration" is a NOUN — a verb pattern of migrat\\w+ wrongly matched it.
  ("skip", "Survey the repository and list every module importing the legacy config loader so we can plan the migration in a later step."),
  ("skip", "Review the authentication flow and report any weaknesses, with file and line references. Never edit the code."),
  ("skip", "Read the deploy notes and summarise the ops constraints for the team. Do not write any code."),
]
bad = [(w, b) for w, b in cases if v(b) != w]
for w, b in bad:
    print("  FAIL  expected=%s got=%s :: %s" % (w, v(b), b[:60]))
print("  ok    classifier %d/%d" % (len(cases) - len(bad), len(cases)) if not bad else "")
sys.exit(1 if bad else 0)
PYC
if [ $? -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo "== fail-open =="
printf 'not json' | "$GATE" >/dev/null 2>&1 && { pass=$((pass+1)); echo "  ok    [fails open] malformed json"; } \
  || { fail=$((fail+1)); echo "  FAIL  malformed json did not exit 0"; }
# NB: `VAR=1 out=$(...)` would only set a shell variable — the subprocess must INHERIT it,
# so export inside a subshell.
out=$(export SERGE_BRIEF_GATE_DISABLE=1; call "$WS/b1" "$CHANGE_B1" Agent off-sess)
[ -z "$out" ] && { pass=$((pass+1)); echo "  ok    [off-switch] SERGE_BRIEF_GATE_DISABLE=1 silences it"; } \
  || { fail=$((fail+1)); echo "  FAIL  off-switch ignored"; }

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
