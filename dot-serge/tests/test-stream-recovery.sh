#!/usr/bin/env bash
# C.3 streaming-smoothness e2e: arm each MID-STREAM fault kind via the
# SERGE_FAULT_INJECT latch and drive REAL headless serge through the REAL
# router. Pass = the turn RECOVERS: the final output contains the expected
# answer and is not the faulted attempt's truncated prefix ("synthetic ").
# HTTP-level kinds (429/quota-403/500) are covered by the StopFailure e2e
# (2026-07-20); this suite owns the in-stream class.
#
# Costs 4 driver requests on the free pool (or paid last rung if pools are
# down). Skips loudly — not silently — if serge/bench env is missing.
set -uo pipefail

# A hardcoded launcher path makes this suite SKIP (exit 1) rather than run
# whenever the checkout is not at exactly that location. Follow the `serge`
# symlink first, then fall back to the historical path.
SERGE_BIN="${SERGE_BIN:-}"
if [ -z "$SERGE_BIN" ]; then
  _s="$(readlink -f "$(command -v serge 2>/dev/null)" 2>/dev/null || true)"
  for _c in ${_s:+"$_s"} "$HOME/programs/serge-0.1.0/serge"; do
    [ -x "$_c" ] && { SERGE_BIN="$_c"; break; }
  done
fi
BENCH_ENV="${SERGE_BENCH_ENV:-$HOME/.serge/evals/swe/bench.env}"
[ -x "$SERGE_BIN" ] || { echo "SKIP: serge launcher not found at $SERGE_BIN"; exit 1; }
[ -f "$BENCH_ENV" ] || { echo "SKIP: bench env not found at $BENCH_ENV"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

WORD="strawberry"
PROMPT="Reply with exactly one word: $WORD"

run_with_fault() {  # $1 = SERGE_FAULT_INJECT value → output file path on stdout
  local kind="$1" out="$T/out-${1//[@x]/-}.txt"
  timeout 300 env SERGE_ENV_FILE="$BENCH_ENV" \
    SERGE_FAULT_INJECT="$kind" \
    SERGE_STREAM_IDLE_TIMEOUT_MS=2000 \
    "$SERGE_BIN" -p "$PROMPT" > "$out" 2>&1
  printf '%s' "$out"
}

for kind in cut midstream-error midstream-quota stall; do
  out=$(run_with_fault "$kind")
  content=$(cat "$out" 2>/dev/null)
  if printf '%s' "$content" | grep -qi "$WORD"; then
    # Recovered — and the faulted attempt's partial text must not be the answer.
    if printf '%s' "$content" | grep -q '^synthetic $'; then
      bad "$kind: answer present but truncated fault prefix surfaced to user"
    else
      ok "$kind: mid-stream fault recovered cleanly (answer delivered)"
    fi
  else
    bad "$kind: no answer after fault — output tail: $(tail -c 160 "$out" 2>/dev/null)"
  fi
done

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — mid-stream faults recover with no user-visible truncation"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
