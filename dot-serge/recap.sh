#!/usr/bin/env bash
# Serge /recap — gather "what just happened" context so Serge can troubleshoot
# something that scrolled past or failed. Three sources, each best-effort and
# clearly labelled; any that's unavailable is skipped with a one-line note so the
# absence is explicit rather than silent. Pure read-only. Safe no-op on any error.
#
#   1. tmux scrollback  — the real terminal history above the prompt (if in tmux)
#   2. router/system logs — serge-router journal + budget-watchdog log (infra stops)
#   3. session transcript — the most recent serge session's recorded steps + errors
#
# Tunables: SERGE_RECAP_LINES (tmux/journal tail, default 200),
#           SERGE_RECAP_TX_EVENTS (transcript events summarised, default 30).
set -uo pipefail

LINES="${SERGE_RECAP_LINES:-200}"
TX_EVENTS="${SERGE_RECAP_TX_EVENTS:-30}"
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"

section() { printf '\n===== %s =====\n' "$1"; }

# --- 1. tmux scrollback ------------------------------------------------------
section "TERMINAL SCROLLBACK (tmux)"
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  # Capture the visible pane plus scrollback history (-S -N = N lines back).
  if ! tmux capture-pane -p -S "-${LINES}" 2>/dev/null; then
    echo "(tmux present but capture-pane failed — pane may be unavailable)"
  fi
else
  echo "(not running inside tmux, or tmux not installed — no terminal scrollback available."
  echo " To get true scrollback here, run serge inside a tmux session.)"
fi

# --- 2. router / system logs -------------------------------------------------
section "SERGE-ROUTER LOG — signal lines (scanned last ${LINES})"
if command -v journalctl >/dev/null 2>&1; then
  # Filter to the lines that matter for troubleshooting (errors, HTTP statuses,
  # caps, retries, the actual provider error message) and drop the multi-line
  # Python-traceback frames that bury the signal. Show the real error text.
  out=$(journalctl --user -u serge-router.service -n "$LINES" --no-pager 2>/dev/null \
        | grep -iE 'error|exception|warning|HTTP/1\.1|stopped|killed|refused|timeout|402|429|5[0-9][0-9] |Retried|[Ff]allback|cap|requires more credits|tokens limit|finish_reason' \
        | grep -vE ':   File "|:     [a-z_]+\(|\^\^\^|, line [0-9]+, in ' \
        | tail -n 30)
  if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(no notable router log lines in the last $LINES)"; fi
else
  echo "(journalctl not available)"
fi

section "ROUTER STATE + BUDGET"
if command -v systemctl >/dev/null 2>&1; then
  printf 'serge-router.service: %s\n' "$(systemctl --user is-active serge-router.service 2>/dev/null || echo unknown)"
  printf 'budget-watchdog.timer: %s\n' "$(systemctl --user is-active serge-budget-watchdog.timer 2>/dev/null || echo unknown)"
fi
[ -f "$SERGE_HOME/monitor/.budget-capped" ] && echo "⚠ .budget-capped flag PRESENT — router was stopped by the daily-spend cap."
if [ -f "$SERGE_HOME/monitor/budget-watchdog.log" ]; then
  echo "-- budget-watchdog.log (last 8) --"
  tail -n 8 "$SERGE_HOME/monitor/budget-watchdog.log" 2>/dev/null
fi

# --- 3. recent session transcript -------------------------------------------
section "RECENT SESSION TRANSCRIPT"
# Claude Code/Serge slugs the project dir from the cwd: EVERY non-alphanumeric
# byte -> '-' (sanitizePath). Mapping only '/' and '.' agreed with that for most
# paths and silently disagreed for any cwd containing '_', '-' or a space, which
# read as "no transcript" rather than as a bug. Long paths (>200 chars) also get
# a hash suffix that bash cannot reproduce; those simply miss, which is why the
# directory check below stays a soft skip.
slug=$(printf '%s' "$PWD" | sed 's#[^a-zA-Z0-9]#-#g')
TXDIR="$SERGE_HOME/projects/$slug"
if [ -d "$TXDIR" ]; then
  newest=$(ls -t "$TXDIR"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$newest" ] && command -v python3 >/dev/null 2>&1; then
    echo "transcript: $newest"
    SERGE_TX="$newest" SERGE_TX_EVENTS="$TX_EVENTS" python3 - <<'PY'
import os, json, collections
f = os.environ["SERGE_TX"]; n = int(os.environ.get("SERGE_TX_EVENTS", "30"))
events = collections.deque(maxlen=n)
errors = []
try:
    with open(f, encoding="utf-8") as fh:
        for line in fh:
            try: e = json.loads(line)
            except Exception: continue
            t = e.get("type")
            if t == "user":
                m = e.get("message") or {}
                c = m.get("content")
                txt = c if isinstance(c, str) else ""
                if isinstance(c, list):
                    # tool_result blocks carry is_error
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                            errors.append("tool_result error")
                    txt = " ".join(b.get("text","") for b in c if isinstance(b, dict) and b.get("type")=="text")
                if txt.strip(): events.append(("user", txt.strip()[:200]))
            elif t == "assistant":
                m = e.get("message") or {}
                for b in (m.get("content") or []):
                    if not isinstance(b, dict): continue
                    if b.get("type") == "text" and b.get("text","").strip():
                        events.append(("assistant", b["text"].strip()[:200]))
                    elif b.get("type") == "tool_use":
                        events.append(("tool", f"{b.get('name','?')} {json.dumps(b.get('input',{}))[:120]}"))
    print(f"(showing last {len(events)} narrative events)")
    for role, txt in events:
        print(f"  [{role}] {txt}")
    if errors:
        print(f"\n  ⚠ {len(errors)} tool error(s) recorded in this transcript.")
except Exception as ex:
    print(f"(could not parse transcript: {ex})")
PY
  else
    echo "(no .jsonl transcript found under $TXDIR, or python3 missing)"
  fi
else
  echo "(no transcript dir for this project at $TXDIR — is this a serge project?)"
fi

printf '\n===== END RECAP =====\n'
