#!/usr/bin/env bash
# Regression test for the two brain-hash safety nets (added 2026-07-28).
#
# Both nets detect "did anything behavior-defining change?" by hashing a file list:
#   1. gate-on-stop.sh   — SERGE_GATE_HASH_GLOBS  → post-edit eval sweep
#   2. loops/run-loop.sh — LOOP_TRIPWIRE_GLOBS    → kill ALL loops on brain edit
#
# Both default lists still name CONSTITUTION.trimmed.v2.md. When the brain moved to
# v3 (+ debugging.md split out) and v2 froze on disk, both went blind to edits of the
# file that actually defines behavior — silently, because a frozen file still hashes
# fine. The loop one matters most: loops run `serge --yolo` unattended, and that
# tripwire is the containment boundary against a loop rewriting Serge's own brain.
#
# Neither script was edited. The fix rides on their documented extension points
# (SERGE_GATE_STOP_SCRIPT → gate-on-stop-globs.sh; loop.conf sourced after defaults),
# so this test pins the OVERRIDES, and case 1 pins the bug they exist to cover.
set -uo pipefail

SH_REAL="${SERGE_HOME:-$HOME/.serge}"
n=0; fails=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails+1)); }

# Mirror of hash_now()/trip_hash() — identical in both scripts.
# shellcheck disable=SC2086
hash_of() { { for f in $1; do [ -f "$f" ] && cat "$f"; done; } 2>/dev/null | sha256sum | cut -d' ' -f1; }

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/agents" "$FAKE/commands"
printf 'v2 frozen rollback target\n' > "$FAKE/CONSTITUTION.trimmed.v2.md"
printf 'v3 ACTIVE personality\n'     > "$FAKE/CONSTITUTION.md"
printf 'full pre-trim original\n'    > "$FAKE/CONSTITUTION.md"
printf 'debugging doctrine\n'        > "$FAKE/debugging.md"
printf 'council overlay\n'           > "$FAKE/council.md"
printf 'reviewer seat\n'             > "$FAKE/agents/reviewer.md"
printf 'a command\n'                 > "$FAKE/commands/thing.md"

OLD_GLOBS="$FAKE/CONSTITUTION.trimmed.v2.md $FAKE/CONSTITUTION.md $FAKE/council.md $FAKE/agents/*.md"

echo "── the bug these overrides exist to cover ──"
n=$((n+1))
before="$(hash_of "$OLD_GLOBS")"
# The ACTIVE constitution is the one CLAUDE.md @-imports: CONSTITUTION.md.
# This edited CONSTITUTION.md, which the default list DOES name — so the check
# reported the default as "fixed upstream" when nothing had been fixed.
printf 'v3 EDITED — new behavior\n' > "$FAKE/CONSTITUTION.md"
after="$(hash_of "$OLD_GLOBS")"
if [ "$before" = "$after" ]; then ok "default list is blind to an ACTIVE-constitution edit"; else bad "default list unexpectedly caught it — has the default been fixed upstream?"; fi

echo
echo "── net 1: gate-on-stop shim (SERGE_GATE_STOP_SCRIPT) ──"
SHIM="$SH_REAL/gate-on-stop-globs.sh"
n=$((n+1))
if [ -x "$SHIM" ]; then ok "shim present and executable"; else bad "shim missing at $SHIM"; fi

# Ask the shim what list it would hand the gate, with SERGE_HOME pointed at the fake.
n=$((n+1))
# Ask the shim directly. The previous version sourced it and read the variable,
# which cannot work — the shim ends in `exec` — and fell back to a hardcoded COPY
# of the list. That copy went stale, so this check was grading the test's own
# duplicate instead of the file under test. No fallback now: an empty answer is
# a failure, because a shim that cannot say what it covers is the bug.
NEW_GLOBS="$(SERGE_HOME="$FAKE" SERGE_GATE_GLOBS_ONLY=1 bash "$SHIM" </dev/null 2>/dev/null)"
case "$NEW_GLOBS" in
  *trimmed.v3*) ok "shim's list covers the ACTIVE constitution" ;;
  *) bad "shim's list is missing v3: $NEW_GLOBS" ;;
esac

for target in CONSTITUTION.md debugging.md CONSTITUTION.trimmed.v2.md council.md; do
  n=$((n+1))
  b="$(hash_of "$NEW_GLOBS")"
  printf 'changed %s at %s\n' "$target" "$n" > "$FAKE/$target"
  a="$(hash_of "$NEW_GLOBS")"
  if [ "$b" != "$a" ]; then ok "edit to $target → gate hash changes"; else bad "edit to $target → gate hash did NOT change"; fi
done

echo
echo "── net 2: loop tripwire (loop.conf override) ──"
for conf in "$SH_REAL"/loops/*/loop.conf; do
  [ -f "$conf" ] || continue
  name="$(basename "$(dirname "$conf")")"
  n=$((n+1))
  # Mirror run-loop.sh's state at the moment it sources loop.conf (lines 36-42):
  # SH/LOOPS/NAME/DIR/CONF are all set first, and several loop.confs reference DIR.
  # Miss those and `set -u` aborts the source before the override line is reached —
  # which looked exactly like "the override is missing" on the first run of this test.
  globs="$(
    SH="$FAKE"
    LOOPS="$SH_REAL/loops"
    NAME="$name"
    DIR="$LOOPS/$NAME"
    CONF="$conf"
    LOOP_TRIPWIRE_GLOBS="$SH/CONSTITUTION.trimmed.v2.md $SH/CONSTITUTION.md $SH/council.md $SH/agents/*.md $SH/commands/*.md"
    # shellcheck disable=SC1090
    . "$conf" >/dev/null 2>&1
    printf '%s' "$LOOP_TRIPWIRE_GLOBS"
  )"
  case "$globs" in
    *trimmed.v3*debugging.md*|*debugging.md*trimmed.v3*)
      b="$(hash_of "$globs")"
      # Unique per loop: writing identical bytes leaves the hash equal and reads as
      # "the tripwire didn't fire" when nothing actually changed.
      printf 'loop %s edited the live constitution (%s)\n' "$name" "$n" > "$FAKE/CONSTITUTION.md"
      a="$(hash_of "$globs")"
      if [ "$b" != "$a" ]; then ok "loop '$name': a --yolo edit of v3 trips the tripwire"; else bad "loop '$name': v3 edit did NOT trip"; fi
      ;;
    *) bad "loop '$name': override missing v3/debugging.md" ;;
  esac
done

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32m✓ ALL %d PASS — both brain-hash nets cover the active constitution\033[0m\n' "$n"
else
  printf '\033[31m✗ %d FAILED, %d passed\033[0m\n' "$fails" "$((n-fails))"; exit 1
fi
