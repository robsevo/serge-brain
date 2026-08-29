#!/usr/bin/env bash
# Serge explanation gate — Stop ($0, no LLM).
#
# WHY: the constitution already requires it twice — `communication` says
# "everything the user needs from a turn ... lands in the final message", and
# `completion_criteria` says a turn closes "with a short summary: what changed,
# any assumptions made, any concern it noticed" and "never ends a turn silently".
# Nothing checked. Observed 2026-08-29: a turn edited a route file, ran the
# checker, updated the todo list, and ended with `✓ Done · 44s` and not one word
# about what it had done — which from the outside is indistinguishable from a
# crash. Doctrine with no gate is a preference.
#
# DELIBERATELY NARROW, the same way task-evidence-gate.sh is narrow: an
# always-on blocker that misfires is worse than no blocker. It fires only when
# BOTH are true:
#
#   1. the turn actually wrote to a file — Edit / Write / MultiEdit /
#      NotebookEdit in THIS turn's transcript slice. A turn that answered a
#      question is none of this hook's business.
#   2. the final assistant message is shorter than SERGE_EXPLAIN_MIN_CHARS
#      (default 200) once whitespace is normalised.
#
# So "Done." after rewriting four files blocks; a real summary never does. The
# bar is length, not judgement, because a gate that grades prose is a gate that
# argues with you.
#
# Opt-in stricter: SERGE_EXPLAIN_REQUIRE_FILES=1 also blocks a summary that
# names none of the files it changed. Off by default — a good summary may
# legitimately say "the session lister" rather than "sessions.mjs", and blocking
# that is exactly the misfire this hook is built to avoid.
#
# BLOCKS ONCE. `stop_hook_active` is set by the engine after any Stop hook
# blocks (loop.mjs), and this returns 0 whenever it is set — so the worst case
# is one extra turn, never a loop. It also stands down on an interrupted turn:
# the user pressed Esc, and demanding a summary of work they just cancelled is
# the "it retries when I try to stop it" bug that stop-checks.sh already guards.
#
# CONTRACT: Stop carries transcript_path, last_assistant_message and
# stop_hook_active. Exit 2 puts stderr in front of the model and re-runs the
# turn. Stop cannot inject additionalContext, so the reason IS the message.
#
# Safety: off-switch SERGE_EXPLAIN_DISABLE=1 · fails open on any error · reads
# only the tail of the transcript · never writes anything.
set -uo pipefail

[ "${SERGE_EXPLAIN_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

reason="$(python3 - "$input" <<'PY' 2>/dev/null
import json, os, re, sys

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "Stop":
    sys.exit(0)

# Already bounced once this turn — say nothing rather than deadlock.
if d.get("stop_hook_active"):
    sys.exit(0)

final = str(d.get("last_assistant_message") or "")

# The user pressed Esc. Whatever is missing from the summary, they did not ask
# for the summary.
if "[Request interrupted by user" in final:
    sys.exit(0)

path = str(d.get("transcript_path") or "")
if not path or not os.path.exists(path):
    sys.exit(0)                                   # nothing to read — fail open

try:
    # The tail is enough: a turn is a suffix of the file by construction, and
    # reading a 40MB transcript to price one turn is the cost this avoids.
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - 4_000_000))
        raw = fh.read().decode("utf-8", "replace")
except Exception:
    sys.exit(0)

lines = raw.split("\n")
if size > 4_000_000:
    lines = lines[1:]                             # a seek mid-line leaves a fragment

entries = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except Exception:
        continue

# THIS turn = everything after the last REAL user prompt. A `user` entry whose
# blocks are tool_result is a tool result, not a new prompt — conflating the two
# makes every turn look like it started fresh (transcript.mjs says so too).
start = 0
for i in range(len(entries) - 1, -1, -1):
    e = entries[i]
    if e.get("type") != "user":
        continue
    content = e.get("message", {}).get("content")
    if isinstance(content, str) or (
        isinstance(content, list) and any(b.get("type") == "text" for b in content if isinstance(b, dict))
    ):
        start = i
        break

WRITERS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
touched = []
for e in entries[start:]:
    if e.get("type") != "assistant":
        continue
    content = e.get("message", {}).get("content")
    if not isinstance(content, list):
        continue
    for b in content:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        if b.get("name") not in WRITERS:
            continue
        p = str((b.get("input") or {}).get("file_path") or "").strip()
        if p and p not in touched:
            touched.append(p)

if not touched:
    sys.exit(0)                                   # nothing was written — not our business

body = " ".join(final.split())
minimum = int(os.environ.get("SERGE_EXPLAIN_MIN_CHARS") or 200)

names = [os.path.basename(p) for p in touched]
shown = ", ".join(names[:6]) + (f" (+{len(names) - 6} more)" if len(names) > 6 else "")

if len(body) < minimum:
    print(
        f"You changed {len(touched)} file(s) — {shown} — and ended the turn with "
        f"{len(body)} characters of explanation. Say what you did before you stop: "
        "what changed and why, anything you assumed, anything you noticed but did "
        "not act on, and what is left. Do not redo the work; just describe it."
    )
    sys.exit(0)

if os.environ.get("SERGE_EXPLAIN_REQUIRE_FILES") == "1":
    low = body.lower()
    if not any(n.lower() in low for n in names):
        print(
            f"Your summary names none of the {len(touched)} file(s) you changed "
            f"({shown}). Name them and say what changed in each."
        )
PY
)"

[ -n "$reason" ] || exit 0
printf '%s\n' "$reason" >&2
exit 2
