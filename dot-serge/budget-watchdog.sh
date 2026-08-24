#!/usr/bin/env bash
# Serge paid-spend watchdog (reworked 2026-07-21 for the $20 OpenRouter budget).
#
# DB-less LiteLLM can't enforce a budget, so this is the hard cap. All four paid
# seats (haiku-paid / sonnet-paid / opus-paid / kimi-coder) ride a DEDICATED env
# var, OPENROUTER_PAID_API_KEY, in router.env. When real OpenRouter spend (the
# provider's own usage_daily / usage_monthly numbers — no local arithmetic)
# crosses a cap, this script swaps THAT var to a LOCKED sentinel and restarts the
# router: paid seats then fail loudly (401) while every free seat — including
# free-qwen, which rides the untouched OPENROUTER_API_KEY — keeps working. On
# day/month rollover the key is restored automatically.
#
# Caps (user call 2026-07-21: "$20 added, ≤$20/month, usage very minimal"):
#   SERGE_MONTHLY_CAP_USD  (default 20)  — the hard monthly budget
#   SERGE_DAILY_CAP_USD    (default 1)   — runaway guard so one bad day can't
#                                          eat the month; unlocks next UTC day
# HEADS-UP: the systemd unit carries a drop-in
# (~/.config/systemd/user/serge-budget-watchdog.service.d/cap.conf) whose
# Environment= lines OVERRIDE these defaults. A stale $10 value there defeated
# the daily guard for a month — change caps in BOTH places or check with
# `systemctl --user show serge-budget-watchdog.service -p Environment`.
# Soft warnings at 50% / 80% of the monthly cap land in NOTIFICATIONS.md once
# per month each.
#
# Fail-safe: any error (no key, network, missing field) → do NOTHING. Never
# touch the router on uncertainty — a false outage is worse than a small
# overshoot.
#
# Test hooks (see tests/test-budget-watchdog.sh):
#   SERGE_WATCHDOG_STUB_KEYJSON / SERGE_WATCHDOG_STUB_CREDJSON  — canned API JSON
#   SERGE_WATCHDOG_DRYRUN=1  — log intended actions, touch nothing
#   SERGE_HOME               — redirect all state/files (tests use a temp dir)
#
# Wired as ~/.config/systemd/user/serge-budget-watchdog.{service,timer} (every 5m).
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
MONTHLY_CAP="${SERGE_MONTHLY_CAP_USD:-20}"
DAILY_CAP="${SERGE_DAILY_CAP_USD:-1}"
DRYRUN="${SERGE_WATCHDOG_DRYRUN:-0}"
ROUTER_UNIT="serge-router.service"
ENVF="$SERGE_HOME/router.env"
MON="$SERGE_HOME/monitor"
LOG="$MON/budget-watchdog.log"
LOCKED_SENTINEL="LOCKED-BUDGET-CAP"
DAYFLAG="$MON/.paid-capped-day"      # contains the UTC day (YYYY-MM-DD) that tripped
MONFLAG="$MON/.paid-capped-month"    # contains the UTC month (YYYY-MM) that tripped
WARNF="$MON/.or-warned"              # "YYYY-MM <pct>" lines — monthly warn dedupe
mkdir -p "$MON" 2>/dev/null || true

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }
notify() { printf -- '- [ ] %s budget-watchdog: %s\n' "$(date -u +%F)" "$*" >> "$SERGE_HOME/NOTIFICATIONS.md" 2>/dev/null || true; }

act() {  # side-effecting command, suppressed in dry-run
  if [ "$DRYRUN" = "1" ]; then log "DRYRUN: would run: $*"; return 0; fi
  "$@"
}

# --- Legacy migration: the pre-2026-07-21 watchdog stopped the WHOLE router ---
if [ -f "$MON/.budget-capped" ]; then
  act systemctl --user start "$ROUTER_UNIT" 2>/dev/null || true
  [ "$DRYRUN" = "1" ] || rm -f "$MON/.budget-capped"
  log "legacy .budget-capped flag found — router restored, flag migrated to paid-seat lockout model"
fi

# --- Paid-seat sentinel: count paid-seat turns in today's transcripts and ------
# surface any INCREASE once via NOTIFICATIONS.md. Detection only — the paid
# rungs are deliberate anti-brick insurance; the cap logic below is the enforcer.
#
# MUST match SERVED names, not just requested seat names (fixed 2026-07-22).
# A transcript records the model LiteLLM actually served: an explicit call to
# the seat logs "haiku-paid", but a FALLBACK into that seat logs the upstream
# id, "anthropic/claude-haiku-4.5". Fallback is exactly how paid seats get hit
# unintentionally, so the seat-name-only pattern was blind to the case it
# existed to catch — it read 0 through the $6.19 day that prompted this fix.
PAIDF="$MON/.paid-seat-hits"
# TZ SKEW: this passed `date -u +%F` — a UTC date — to `-newermt`, which parses a
# bare date in LOCAL time. Anywhere west of UTC the two disagree for the last hours
# of every local day: the cutoff becomes a LOCAL midnight that has not happened yet,
# the find matches nothing, and this tripwire reads 0 paid turns — then writes that
# 0 over .paid-seat-hits, clobbering the day's running total. That is exactly the
# blindness the served-name regression test guards, reintroduced through the date
# format. Fix: a full ISO-8601 instant with an explicit Z, so the cutoff is real UTC
# midnight and stays consistent with the UTC day/month keys used further down.
paid_now=$(find "$SERGE_HOME/projects" -name '*.jsonl' -newermt "$(date -u +%FT00:00:00Z)" 2>/dev/null \
  | xargs -r grep -hoE '"model": ?"(haiku-paid|sonnet-paid|opus-paid|kimi-coder|cheap-paid|anthropic/claude-haiku-4\.5|anthropic/claude-sonnet-5|anthropic/claude-opus-4\.8|moonshotai/kimi-k2\.5|qwen/qwen3-coder-next)"' 2>/dev/null | wc -l)
paid_prev=$(cat "$PAIDF" 2>/dev/null || echo 0)
case "$paid_prev" in ''|*[!0-9]*) paid_prev=0;; esac
if [ "${paid_now:-0}" -gt "$paid_prev" ]; then
  log "PAID SEAT HIT: $((paid_now - paid_prev)) new paid-model turn(s) today (total $paid_now)"
  notify "$paid_now paid-seat turn(s) today (cheap-paid, haiku/sonnet/opus-paid or kimi-coder) — check /cost for real spend"
fi
printf '%s\n' "${paid_now:-0}" > "$PAIDF" 2>/dev/null || true

# Refresh the quota-gauge cache (statusline + /cost read it). Best-effort.
bash "$SERGE_HOME/quota.sh" >/dev/null 2>&1 || true

# --- Real spend from OpenRouter (the REAL key — never the paid alias, which ---
# may be locked). Stubs let tests inject canned JSON with zero network.
key="${OPENROUTER_API_KEY:-}"
if [ -z "$key" ] && [ -f "$ENVF" ]; then
  key=$(grep -E '^OPENROUTER_API_KEY=' "$ENVF" | head -1 | cut -d= -f2-)
  key=${key%$'\r'}; key=${key#[\"\']}; key=${key%[\"\']}
fi
if [ -n "${SERGE_WATCHDOG_STUB_KEYJSON:-}" ]; then
  keyjson="$SERGE_WATCHDOG_STUB_KEYJSON"
  credjson="${SERGE_WATCHDOG_STUB_CREDJSON:-}"
else
  [ -z "$key" ] && { log "no OPENROUTER_API_KEY — skipping (fail-safe)"; exit 0; }
  command -v python3 >/dev/null 2>&1 || { log "no python3 — skipping"; exit 0; }
  keyjson=$(curl -sf --max-time 15 https://openrouter.ai/api/v1/key -H "Authorization: Bearer $key" 2>/dev/null)
  credjson=$(curl -sf --max-time 15 https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $key" 2>/dev/null)
fi
[ -z "$keyjson" ] && { log "OpenRouter unreachable — skipping (fail-safe)"; exit 0; }

read -r daily monthly < <(KEYJSON="$keyjson" python3 -c '
import os, json
try:
    d = json.loads(os.environ["KEYJSON"]).get("data", {})
    dv, mv = d.get("usage_daily"), d.get("usage_monthly")
    print(f"{float(dv):.4f} {float(mv):.4f}" if dv is not None and mv is not None else "")
except Exception:
    print("")
' 2>/dev/null)
[ -z "${daily:-}" ] || [ -z "${monthly:-}" ] && { log "usage_daily/monthly missing — skipping (fail-safe)"; exit 0; }

# Cache the real numbers for cost.sh / quota.sh (display only, best-effort).
export SERGE_MON="$MON"
KEYJSON="$keyjson" CREDJSON="${credjson:-}" DAILY="$daily" MONTHLY="$monthly" MONTHLY_CAP="$MONTHLY_CAP" \
python3 -c '
import os, json, time
out = {"ts": int(time.time()), "daily": float(os.environ["DAILY"]),
       "monthly": float(os.environ["MONTHLY"]), "monthly_cap": float(os.environ["MONTHLY_CAP"])}
try:
    c = json.loads(os.environ["CREDJSON"]).get("data", {})
    out["credit_total"] = float(c["total_credits"]); out["credit_used"] = float(c["total_usage"])
    out["credit_left"] = out["credit_total"] - out["credit_used"]
except Exception:
    pass
open(os.path.join(os.environ["SERGE_MON"], "or-spend.json"), "w").write(json.dumps(out))
' 2>/dev/null || true

today=$(date -u +%Y-%m-%d)
thismonth=$(date -u +%Y-%m)
fnum() { python3 -c "print(1 if float('$1') >= float('$2') else 0)" 2>/dev/null || echo 0; }

# --- Soft warnings at 50% / 80% of the monthly cap (once per month each) ------
for pct in 80 50; do
  thresh=$(python3 -c "print(float('$MONTHLY_CAP') * $pct / 100)" 2>/dev/null) || continue
  if [ "$(fnum "$monthly" "$thresh")" = "1" ]; then
    if ! grep -q "^$thismonth $pct\$" "$WARNF" 2>/dev/null; then
      printf '%s %s\n' "$thismonth" "$pct" >> "$WARNF" 2>/dev/null || true
      log "WARN: monthly spend \$$monthly ≥ ${pct}% of \$$MONTHLY_CAP cap"
      notify "OpenRouter spend \$$monthly this month — past ${pct}% of the \$$MONTHLY_CAP cap"
    fi
    break   # only the highest crossed threshold matters
  fi
done

# --- Lock / unlock ------------------------------------------------------------
is_locked=0
grep -qE "^OPENROUTER_PAID_API_KEY=$LOCKED_SENTINEL\$" "$ENVF" 2>/dev/null && is_locked=1

swap_paid_key() {  # $1 = new value; atomic in-place rewrite of router.env
  NEWVAL="$1" ENVF="$ENVF" python3 - <<'PY'
import os
envf, newval = os.environ["ENVF"], os.environ["NEWVAL"]
lines = open(envf).read().splitlines(True)
out, seen = [], False
for ln in lines:
    if ln.startswith("OPENROUTER_PAID_API_KEY="):
        out.append(f"OPENROUTER_PAID_API_KEY={newval}\n"); seen = True
    else:
        out.append(ln)
if not seen:
    out.append(f"OPENROUTER_PAID_API_KEY={newval}\n")
tmp = envf + ".tmp"
open(tmp, "w").write("".join(out))
os.replace(tmp, envf)
PY
}

over_daily=$(fnum "$daily" "$DAILY_CAP")
over_monthly=$(fnum "$monthly" "$MONTHLY_CAP")

# `serge --uncap` lifts TODAY's daily cap (writes .uncap-day = today, UTC).
# The monthly cap is never lifted — that's the hard $20 budget.
if [ -f "$MON/.uncap-day" ] && [ "$(cat "$MON/.uncap-day" 2>/dev/null)" = "$today" ]; then
  over_daily=0
fi

if [ "$over_daily" = "1" ]; then
  [ "$DRYRUN" = "1" ] || printf '%s\n' "$today" > "$DAYFLAG"
fi
if [ "$over_monthly" = "1" ]; then
  [ "$DRYRUN" = "1" ] || printf '%s\n' "$thismonth" > "$MONFLAG"
fi

if { [ "$over_daily" = "1" ] || [ "$over_monthly" = "1" ]; } && [ "$is_locked" = "0" ]; then
  reason="daily \$$daily ≥ \$$DAILY_CAP"; [ "$over_monthly" = "1" ] && reason="monthly \$$monthly ≥ \$$MONTHLY_CAP"
  if [ "$DRYRUN" = "1" ]; then
    log "DRYRUN: would LOCK paid seats ($reason) — swap key + restart router"
  else
    swap_paid_key "$LOCKED_SENTINEL" \
      && act systemctl --user restart "$ROUTER_UNIT" \
      && log "CAP HIT: $reason — paid seats LOCKED (free seats unaffected)" \
      && notify "paid seats LOCKED ($reason) — auto-restores on rollover; free seats unaffected" \
      || log "CAP HIT ($reason) but lock FAILED — check router.env / systemctl"
  fi
fi

# Unlock when every tripped period has rolled over (daily flag: new UTC day;
# monthly flag: new UTC month). usage_* reset on OpenRouter's clock, so the
# over_* checks above immediately re-trip if the provider still reports overage.
if [ "$is_locked" = "1" ]; then
  still=0
  [ -f "$DAYFLAG" ] && [ "$(cat "$DAYFLAG" 2>/dev/null)" = "$today" ] && still=1
  [ -f "$MONFLAG" ] && [ "$(cat "$MONFLAG" 2>/dev/null)" = "$thismonth" ] && still=1
  { [ "$over_daily" = "1" ] || [ "$over_monthly" = "1" ]; } && still=1
  if [ "$still" = "0" ]; then
    if [ "$DRYRUN" = "1" ]; then
      log "DRYRUN: would UNLOCK paid seats (rollover) — restore key + restart router"
    elif [ -z "$key" ]; then
      log "rollover but no real key to restore — skipping (fail-safe)"
    else
      swap_paid_key "$key" \
        && act systemctl --user restart "$ROUTER_UNIT" \
        && rm -f "$DAYFLAG" "$MONFLAG" \
        && log "rollover — paid seats RESTORED" \
        || log "rollover restore FAILED — check router.env / systemctl"
    fi
  fi
fi
exit 0
