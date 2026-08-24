#!/usr/bin/env bash
# SessionStart(clear|resume|compact) hook — warn when this long-lived serge
# process predates the last build of dist/cli.mjs, i.e. bug fixes exist on disk
# but are NOT loaded into the running process.
#
# Why: /clear reuses the process. The 2026-07-10 bare "API Error" ghost was
# exactly this — a session "started" (via /clear) hours after a rebuild still
# ran week-old code, so already-fixed interrupt bugs kept biting and the new
# diagnostics stayed silent. This makes staleness visible the moment a new
# session begins inside an old process.
#
# Cheap and silent when fresh; prints a systemMessage only when stale.
set -uo pipefail

# A HARDCODED default only works while the install lives at exactly that path.
# Move or rename the checkout and the file stops existing, at which point the
# `[ -f "$BIN" ] || exit 0` below turns this watchdog into a silent no-op — the
# very failure it exists to catch (running stale code with no warning). Resolve
# the SAME way the launcher resolves itself: follow the `serge` symlink to the
# real script directory. SERGE_DIST_PATH still wins; the old location stays as a
# last-resort fallback.
if [ -n "${SERGE_DIST_PATH:-}" ]; then
  BIN="$SERGE_DIST_PATH"
else
  _serge_real="$(readlink -f "$(command -v serge 2>/dev/null)" 2>/dev/null || true)"
  BIN=""
  for _cand in \
    ${_serge_real:+"$(dirname "$_serge_real")/dist/cli.mjs"} \
    "$HOME/programs/serge-0.1.0/dist/cli.mjs"
  do
    [ -f "$_cand" ] && { BIN="$_cand"; break; }
  done
fi
[ -n "$BIN" ] && [ -f "$BIN" ] || exit 0

# Walk up from the hook shell to the serge node process (title is 'serge';
# some spawn paths interpose an extra shell).
pid=$PPID
found=""
for _ in 1 2 3 4 5; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$comm" in
    serge|node) found="$pid"; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ] || break
done
[ -n "$found" ] || exit 0

start_s=$(date -d "$(ps -o lstart= -p "$found" 2>/dev/null)" +%s 2>/dev/null) || exit 0
bin_s=$(stat -c %Y "$BIN" 2>/dev/null) || exit 0
[ -n "$start_s" ] && [ -n "$bin_s" ] || exit 0

# 60s slack avoids firing on the boot race right after a build-then-launch.
if [ "$bin_s" -gt $((start_s + 60)) ]; then
  mins=$(( (bin_s - start_s) / 60 ))
  printf '{"systemMessage":"⚠️  Serge was rebuilt AFTER this process started (binary is ~%s min newer than the process). Fixes on disk are NOT loaded — exit serge and relaunch to pick them up."}\n' "$mins"
fi
exit 0
