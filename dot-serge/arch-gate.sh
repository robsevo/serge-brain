#!/usr/bin/env bash
# PostToolUse hook — compute the ARCHITECTURE of the code that was just written.
#
# WHY THIS EXISTS. algo-gate.sh prices the algorithm; semgrep-scan.sh checks
# security patterns. Neither computes STRUCTURE. Nothing built the dependency
# graph, so a cycle could be introduced and nothing noticed; nothing measured
# coupling, so a module could grow forty imports; nothing checked whether a test
# could fail.
#
# That gap is not theoretical. On 2026-08-22 a session shipped serge-engine.ts:
# 343 lines, zero network calls, imported only by the three scripts written
# beside it, "verified" by a probe that passed on any output over 50 characters.
# Every one of those is a computable property. This gate computes them.
#
# WHAT MAKES IT DIFFERENT FROM ASKING. A gate that greps a plan for "Security:"
# is defeated by writing "Security: N/A". Everything here is derived from the
# code itself — Tarjan over the import graph, a structural walk of the source.
# A model cannot predict its way past a cycle it actually created.
#
# SCOPE: only the file this edit touched, and only cycles running THROUGH it.
# Being told about a legacy module's coupling is noise; being told about the
# cycle you closed thirty seconds ago is a fix. You own what you touched.
#
# BLOCKING: high severity blocks (exit 2), the rest rides along as context.
#   high   = cycles, orphan/self-referential modules, god objects, swallowed
#            errors, unbounded resources, N+1, missing rollback, tests that
#            cannot fail. Each is a defect, not a preference.
#   medium = complexity, coupling, wrong container. Real, but a judgment call
#            against a threshold, so it informs rather than stops.
#
# Thresholds are calibrated opinions, not theorems — every one is tunable:
#   SERGE_ARCH_FANOUT / _CYCLO / _NESTING / _FUNC_LINES / _ARITY / _GOD_LOC
#
# Toggles:
#   SERGE_ARCH_GATE_DISABLE=1     off entirely
#   SERGE_ARCH_ADVISORY=1         never block; report everything as context
#   SERGE_ARCH_MAX_FINDINGS=6     cap per message (keeps feedback actionable)
set -uo pipefail

[ "${SERGE_ARCH_GATE_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the MODEL, not the scaffolding — same guard as algo-gate.sh.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Resolve against the ACTIVE config dir, not a hardcoded ~/.serge: install.sh
# supports SERGE_HOME=<anywhere>, and the launcher exports CLAUDE_CONFIG_DIR.
_SERGE_HOME="${SERGE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.serge}}"
SCAN="${SERGE_ARCHSCAN:-$_SERGE_HOME/lib/archscan.py}"
[ -f "$SCAN" ] || exit 0

input="$(cat)"

python3 - "$input" "$SCAN" <<'PY'
import json, os, subprocess, sys

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)                      # unreadable input proves nothing — fail open

import re

scan = sys.argv[2]
tool = d.get("tool_name") or ""
ti = d.get("tool_input") or {}
cwd = d.get("cwd") or os.getcwd()

SRC_EXT = (".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts", ".py")

# Shell forms that write a file. Measured 2026-08-22: writing source through a
# Bash heredoc skipped EVERY PostToolUse code gate — semgrep, algo-gate,
# doc-reality and this one — because all of them matched only Edit|Write|
# MultiEdit. The bypass is not hypothetical: a model denied the Write tool
# reaches for Bash on the very next call, which is exactly what was observed.
# So the gate follows the write, not the tool that made it.
BASH_WRITE = re.compile(
    r">>?\s*([^\s;&|<>()]+)"                       # > f   >> f   cat <<EOF > f
    r"|\btee\s+(?:-a\s+)?([^\s;&|<>()]+)"         # tee f
    r"|\bsed\s+-i\S*\s+.*?\s([^\s;&|<>()]+)\s*$"  # sed -i ... f
    r"|\b(?:cp|mv|install)\s+(?:-\S+\s+)*\S+\s+([^\s;&|<>()]+)",
    re.M)


def source_targets(paths):
    out = []
    for raw in paths:
        if not raw:
            continue
        pth = raw.strip().strip("'\"")
        if pth.startswith(("/dev/", "-")) or "$" in pth or "*" in pth:
            continue
        if not os.path.splitext(pth)[1].lower() in SRC_EXT:
            continue
        full = pth if os.path.isabs(pth) else os.path.join(cwd, pth)
        if os.path.isfile(full):
            out.append(os.path.realpath(full))
    return list(dict.fromkeys(out))


if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    targets = source_targets([ti.get("file_path") or ti.get("path") or ""])
elif tool == "Bash":
    cmd = str(ti.get("command") or "")
    hits = [g for m in BASH_WRITE.finditer(cmd) for g in m.groups() if g]
    targets = source_targets(hits)
else:
    sys.exit(0)

if not targets:
    sys.exit(0)
path = targets[0]

# Find the project root: the nearest ancestor with a manifest or .git. Without
# this the graph is built from an arbitrary directory and fan-in is meaningless.
root = os.path.dirname(os.path.realpath(path))
probe = root
for _ in range(12):
    if any(os.path.exists(os.path.join(probe, m))
           for m in ("package.json", "pyproject.toml", "setup.py", ".git")):
        root = probe
        break
    nxt = os.path.dirname(probe)
    if nxt == probe:
        break
    probe = nxt

try:
    r = subprocess.run([sys.executable, scan, root] + targets,
                       capture_output=True, text=True, timeout=120)
    out = json.loads(r.stdout or "{}")
except Exception:
    sys.exit(0)                      # a gate that cannot run has proved nothing

findings = out.get("findings") or []
if not findings:
    sys.exit(0)

advisory = os.environ.get("SERGE_ARCH_ADVISORY") == "1"
try:
    cap = int(os.environ.get("SERGE_ARCH_MAX_FINDINGS", "6"))
except ValueError:
    cap = 6

high = [f for f in findings if f["severity"] == "high"]
rest = [f for f in findings if f["severity"] != "high"]

def render(fs):
    lines = []
    for f in fs[:cap]:
        loc = "%s:%s" % (f["file"], f["line"])
        lines.append("  [%s] %s — %s" % (f["severity"], loc, f["msg"]))
        lines.append("        fix: %s" % f["fix"])
    if len(fs) > cap:
        lines.append("  … and %d more" % (len(fs) - cap))
    return "\n".join(lines)

# ── loop guard ───────────────────────────────────────────────────────────────
# Re-blocking on a finding the model already saw and chose not to fix burns the
# session: it edits, is blocked, edits again, is blocked again, forever. The
# house pattern (algo-gate, vague-delete-gate) is one block per distinct
# finding-set per file; a CHANGED set blocks again, so real progress is not
# punished and stagnation is not rewarded.
#
# Findings that survive a block still ride along as context, so nothing is
# hidden — the gate simply stops being a wall the second time.
import hashlib, tempfile

if high and not advisory:
    sig = hashlib.sha1(
        ("|".join(sorted("%s:%s:%s" % (f["file"], f["line"], f["kind"]) for f in high))
         ).encode()).hexdigest()[:16]
    guard = os.path.join(
        tempfile.gettempdir(),
        "serge-arch-%s.seen" % hashlib.sha1(
            (str(d.get("session_id") or "nosid") + "|".join(targets)).encode()).hexdigest()[:12])
    prev = ""
    try:
        with open(guard) as fh:
            prev = fh.read().strip()
    except Exception:
        pass
    if prev == sig:
        advisory = True              # said it once; fall through to context
    else:
        try:
            with open(guard, "w") as fh:
                fh.write(sig)
        except Exception:
            pass

if high and not advisory:
    msg = [
        "Architecture gate: %d structural defect(s) in the code you just wrote." % len(high),
        "",
        render(high + rest),
        "",
        "These are computed from the dependency graph and the source, not inferred from "
        "prose — the cycle, the orphan, the swallowed error and the assertion-free test "
        "are facts about the code as it now exists on disk.",
        "Fix them before continuing. If one is a deliberate, correct choice, say why in a "
        "comment at that line so the next reader does not have to re-derive it.",
    ]
    sys.stderr.write("\n".join(msg) + "\n")
    sys.exit(2)

body = render(high + rest)
if body.strip():
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "Architecture notes on the code you just wrote:\n" + body,
    }}))
sys.exit(0)
PY
