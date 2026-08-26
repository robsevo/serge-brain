#!/usr/bin/env bash
# Serge progress loader — SessionStart hook (startup | resume | compact).
#
# Long-horizon tasks can outlive the context window: the harness compacts the
# transcript and detail is lost. This hook makes a per-project PROGRESS.md survive
# that — on every session start AND after a compaction, it injects the project's
# progress file (if any) plus its canonical path as additionalContext, so Serge
# resumes from where it left off instead of re-deriving state from scratch.
#
# The file is MODEL-written: Serge maintains it per the constitution's
# `## execution` → `progress` rule. This hook only READS + injects it, and ensures
# the directory exists so the model's write can't fail. Per-project, stored under
# ~/.serge/projects/<encoded-cwd>/PROGRESS.md (encoding: every non-alphanumeric
# byte → "-", the same key Serge uses for its session dirs) — NOT in the user's
# repo.
#
# jq is NOT installed on this host — JSON via python3, like Serge's other hooks.
# Safe no-op when: no python3. Must exit 0 and write ONLY to stdout so the harness
# can inject the additionalContext.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

# cwd from the SessionStart JSON; fall back to the hook's own working dir.
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("cwd") or "")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# Encode cwd the way Serge keys its per-project dirs: every non-alphanumeric
# byte → "-" (sanitizePath). Mapping only "/" and "." matched for plain paths
# and diverged for any cwd holding "_", "-" or a space — and a wrong key here
# does not error, it just writes PROGRESS.md into a directory nothing reads.
enc="$(printf '%s' "$cwd" | sed 's#[^a-zA-Z0-9]#-#g')"
PROJ_DIR="${SERGE_PROJECTS_DIR:-$HOME/.serge/projects}/$enc"
PROGRESS_FILE="$PROJ_DIR/PROGRESS.md"

mkdir -p "$PROJ_DIR" 2>/dev/null || true   # so the model's later write can't fail

python3 - "$PROGRESS_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
body = ""
if os.path.isfile(path):
    try:
        body = open(path, encoding="utf-8").read().strip()
    except Exception:
        body = ""
if body:
    ctx = ("Serge resume context — this project has an IN-PROGRESS task. Its progress "
           "file is below; read it and continue from the 'next step'. Keep it current at "
           "checkpoints and DELETE it once the task is fully done.\nPath: " + path
           + "\n\n----- PROGRESS.md -----\n" + body)
else:
    ctx = ("No active progress file for this project. If the current task is long-horizon "
           "(could outlive the context window / trigger a compaction), maintain one at "
           + path + " per the constitution's `## execution` → progress rule, so it survives "
           "compaction. Short tasks need none.")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
exit 0
