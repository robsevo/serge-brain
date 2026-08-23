#!/usr/bin/env bash
# Additive shim (2026-07-28) — fixes the eval gate's blind spot WITHOUT editing
# gate-on-stop.sh.
#
# WHY THIS EXISTS
# gate-on-stop.sh decides "did anything behavior-defining change?" by hashing a
# default file list that still names CONSTITUTION.trimmed.v2.md. The brain moved to
# v3 on 2026-07-28 (CLAUDE.md @-imports it; ## debugging split out to debugging.md),
# and v2 stayed on disk frozen. So the gate hashes a file that can no longer change
# and misses the two that define behavior: editing the ACTIVE constitution triggers
# no eval sweep at all. council.md and agents/*.md were still covered — the hole is
# the constitution itself.
#
# WHY A SHIM AND NOT A ONE-TOKEN EDIT
# gate-on-stop.sh already exposes SERGE_GATE_HASH_GLOBS as a documented toggle, and
# stop-checks.sh already exposes SERGE_GATE_STOP_SCRIPT to swap the gate binary. Both
# are extension points, so the fix rides on top instead of forking the script — it
# survives any future rewrite of gate-on-stop.sh, and `git diff` on the brain stays
# empty. Wiring: SERGE_GATE_STOP_SCRIPT in ~/.serge/serge.env points here.
#
# WHY NOT JUST EXPORT SERGE_GATE_HASH_GLOBS DIRECTLY IN serge.env
# The wrapper sources serge.env with `set -a` (serge:62-66), so the value would be
# exported into EVERY child — including evals/tests/stop-gate-selftest.sh, which
# redirects SERGE_HOME to a temp dir and calls gate-on-stop.sh directly. An absolute
# glob list baked into the environment would make that selftest hash the real ~/.serge
# instead of its fixtures, and its "changed → gate" case would silently stop testing
# anything. Resolving $SERGE_HOME here, at call time, keeps the selftest honest: it
# never routes through stop-checks.sh, so it never sees this file.
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"

# Both trimmed versions on purpose: v2 is the documented rollback target, so it is
# behavior-defining the moment CLAUDE.md points back at it. debugging.md is doctrine
# the constitution tells Serge to read by path — a change there changes behavior just
# as much as an inline section did before the split.
#
# CORRECTED 2026-08-23. This shim exists to stop the gate hashing a frozen file —
# and it named v2 and not v3, listing CONSTITUTION.md twice in v3's place. On this
# install CONSTITUTION.md does not exist at all, so the list hashed: a missing file,
# a frozen file, the same missing file, and three that are not the constitution.
# The ACTIVE constitution — the one CLAUDE.md @-imports — was covered by nothing,
# which is the exact hole the shim was written to close. CONSTITUTION.md stays in
# the list because a fresh install from the public brain has that name and no v3.
# `*` stays literal inside the quotes; gate-on-stop.sh expands it unquoted.
: "${SERGE_GATE_HASH_GLOBS:=$SH/CONSTITUTION.md $SH/CONSTITUTION.md $SH/CONSTITUTION.trimmed.v2.md $SH/debugging.md $SH/council.md $SH/agents/*.md}"
export SERGE_GATE_HASH_GLOBS

# Introspection: print the list and stop. Without this there is no way to ASK
# the shim what it covers — `exec` below replaces the shell, so anything trying
# to source this and read the variable gets nothing back. The test that guards
# this file worked around that by hardcoding a COPY of the list, which then went
# stale and asserted against itself: it reported the list as missing v3 while
# the shim was correct, and would equally have reported it correct while the
# shim was wrong.
if [ "${SERGE_GATE_GLOBS_ONLY:-0}" = "1" ]; then
  printf '%s\n' "$SERGE_GATE_HASH_GLOBS"
  exit 0
fi

# exec preserves stdin — gate-on-stop.sh reads the Stop payload from it.
exec bash "${SERGE_GATE_STOP_REAL:-$SH/gate-on-stop.sh}" "$@"
