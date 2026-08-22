#!/usr/bin/env bash
# PreToolUse hook on ExitPlanMode — inspect the plan BEFORE the user is asked
# to approve it.
#
# THE GAP THIS CLOSES. ExitPlanMode is the moment Serge stops planning and
# starts changing files. Until now it carried exactly one hook — persist-plan.sh
# on PostToolUse — whose own header says it "NEVER blocks... always exits 0
# (fail-open)". So the plan was SAVED but never INSPECTED, and it reached the
# user for approval having been checked for nothing.
#
# WHY GROUNDED CHECKS AND NOT A CHECKLIST. A gate that greps for "Security:" is
# defeated by writing "Security: N/A" — that is the claims-block failure in a
# new costume, and it is worse than nothing because a passed gate reads as
# assurance. So the checks are ordered by how hard they are to fake:
#
#   rung 1  cited files exist               <- the filesystem answers
#   rung 2  cited symbols are findable      <- grep answers
#   rung 3  depth vs blast radius           <- arithmetic answers
#   rung 4  a verification clause per step  <- structure answers
#
# The first two are load-bearing. A plan citing src/services/auth.ts in a repo
# with no such file was written from imagination, and that single check catches
# the whole class of confident-fictional planning that produced serge-engine.ts.
#
# TIERS — so the discipline does not become a tax. The fastest way to kill a
# gate like this is to make it fire on a typo fix:
#   T0  1 file, local            -> nothing required
#   T1  1-3 files                -> citations + verification + the boundary
#   T2  4-10 files, or a boundary crossed -> T1 + a rejected alternative
#   T3  schema/auth/protocol, or >10 files -> T2 + 10x behaviour, failure modes,
#                                             and a rollback path
#
# This is reconciled with RULES.md's "No Enterprise Bloat" and YAGNI: the gate
# requires the question to be ANSWERED, never that infrastructure be BUILT.
# "n stays under 100 here, a linear scan is correct and an index would be waste"
# is a complete, passing answer.
#
# Toggles:
#   SERGE_PLAN_GATE_DISABLE=1   off entirely
#   SERGE_PLAN_GATE_ADVISORY=1  never block; return notes as context
#   SERGE_PLAN_MIN_TIER=2       lowest tier that may block (default 2)
set -uo pipefail

[ "${SERGE_PLAN_GATE_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import json, os, re, subprocess, sys

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if (d.get("tool_name") or "") != "ExitPlanMode":
    sys.exit(0)

ti = d.get("tool_input") or {}
plan = str(ti.get("plan") or ti.get("content") or "").strip()
if not plan:
    sys.exit(0)

cwd = d.get("cwd") or os.getcwd()

# ── what does the plan claim to touch? ───────────────────────────────────────
# A path-shaped token: has a separator or a known source extension. Deliberately
# conservative — a false "you cited a file that does not exist" is expensive.
PATH_RE = re.compile(
    r"`([^`\n]+?)`|(?<![\w/.])((?:[\w.-]+/)+[\w.-]+\.[A-Za-z]{1,5})(?![\w/])")
EXTS = (".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".py", ".go",
        ".rs", ".rb", ".java", ".sh", ".sql", ".json", ".yaml", ".yml", ".toml", ".md")

cited = []
for m in PATH_RE.finditer(plan):
    tok = (m.group(1) or m.group(2) or "").strip()
    if not tok or " " in tok:
        continue
    if not tok.endswith(EXTS):
        continue
    if tok.startswith(("http://", "https://")):
        continue
    cited.append(tok.lstrip("./"))
cited = list(dict.fromkeys(cited))

# A path may be marked new; then it is not expected to exist yet.
NEW_MARK = re.compile(r"\(new\)|\bnew file\b|\bcreate[sd]?\b|\badd(?:ing|s)?\b", re.I)

def marked_new(path):
    for line in plan.splitlines():
        if path in line and NEW_MARK.search(line):
            return True
    return False

missing = []
for c in cited:
    if marked_new(c):
        continue
    hit = os.path.exists(os.path.join(cwd, c))
    if not hit:
        # tolerate a repo-root-relative path written from a subdirectory
        base = os.path.basename(c)
        try:
            r = subprocess.run(["find", cwd, "-name", base, "-not", "-path", "*/node_modules/*",
                                "-not", "-path", "*/.git/*", "-maxdepth", "6"],
                               capture_output=True, text=True, timeout=15)
            hit = bool(r.stdout.strip())
        except Exception:
            hit = True                      # cannot check -> do not accuse
    if not hit:
        missing.append(c)

# ── tier ─────────────────────────────────────────────────────────────────────
n_files = len(cited)

# HEAVY escalates to T3 — but only on a CHANGE to sensitive machinery, not on
# any mention of it. "refactor the token refresh in two files" is a small local
# change that happens to say "token"; demanding a rollback plan for it is the
# false positive that gets a gate disabled in a week. So the vocabulary must be
# paired with a structural verb, or the change must already be broad.
HEAVY_NOUN = re.compile(
    r"\b(schema|migration|migrate|auth|authz|authent|token|session|protocol|"
    r"encrypt|password|credential|payment|tenant|permission)\b", re.I)
STRUCTURAL_VERB = re.compile(
    r"\b(add|introduce|create|new|drop|remove|delete|alter|change|replace|"
    r"redesign|rewrite|restructure|rotate|expire|invalidate)\b", re.I)

def heavy_change():
    """Sensitive noun and structural verb in the SAME sentence."""
    for sent in re.split(r"[.\n;]", plan):
        if HEAVY_NOUN.search(sent) and STRUCTURAL_VERB.search(sent):
            return True
    return False

tier = 0
if n_files >= 1:
    tier = 1
if n_files >= 4:
    tier = 2
if n_files > 10 or (heavy_change() and n_files >= 3):
    tier = 3
# A schema or migration change is T3 at any size — an unrollbackable migration
# is a production incident whether it touches one file or ten.
if re.search(r"\b(schema|migration|migrate)\b", plan, re.I) and STRUCTURAL_VERB.search(plan):
    tier = 3

try:
    min_tier = int(os.environ.get("SERGE_PLAN_MIN_TIER", "2"))
except ValueError:
    min_tier = 2

# ── structural expectations, by tier ─────────────────────────────────────────
def has(*pats):
    return any(re.search(p, plan, re.I | re.S) for p in pats)

problems = []

if missing:
    problems.append(
        "Cites %d file(s) that do not exist and are not marked new: %s.\n"
        "      Either the path is wrong or the plan was written without reading the repo. "
        "If the file is to be created, mark it (new)."
        % (len(missing), ", ".join(missing[:6])))

if tier >= 1:
    if not has(r"\bverif", r"\btest\b", r"\bcheck(ed|s)?\b", r"\bconfirm",
               r"\bassert", r"\bmeasure"):
        problems.append(
            "No step says how it will be VERIFIED. A plan whose steps cannot be checked "
            "produces a turn that reports success without evidence.")
    if not has(r"does not\b", r"out of scope", r"\bnot doing\b", r"\bwon'?t\b",
               r"\bexclud", r"\bdefer"):
        problems.append(
            "The plan never states its BOUNDARY — what it deliberately does not do. "
            "Unstated scope is where scope creep and 'I assumed you wanted' live.")

if tier >= 2:
    if not has(r"\binstead of\b", r"\balternative\b", r"\brejected\b", r"\bconsidered\b",
               r"\brather than\b", r"\bchose .* over\b", r"\btrade-?off"):
        problems.append(
            "No ALTERNATIVE is named. State one real approach you rejected and why — "
            "if you cannot name one, the design space was not explored.")

if tier >= 3:
    if not has(r"\b10x\b", r"\bscal", r"\bgrow", r"\bunder load\b", r"\bthroughput\b",
               r"\bn (?:is|stays|remains)\b", r"\bO\("):
        problems.append(
            "Tier 3 change with no statement about BEHAVIOUR AT SCALE. State what n is and "
            "what happens at 10x. 'n stays under 100, a linear scan is correct' is a "
            "complete answer — the requirement is to have decided, not to build for scale.")
    if not has(r"\bfail", r"\berror\b", r"\btimeout\b", r"\bretry\b", r"\bpartial\b",
               r"\bdegrade"):
        problems.append(
            "Tier 3 change with no named FAILURE MODES. What breaks, and what happens when "
            "it does?")
    if not has(r"\brollback\b", r"\brevert\b", r"\bundo\b", r"\bdown migration\b",
               r"\bback ?out\b", r"\brestore\b"):
        problems.append(
            "Tier 3 change with no ROLLBACK path. How is this reversed in production if it "
            "is wrong?")

if not problems:
    sys.exit(0)

advisory = os.environ.get("SERGE_PLAN_GATE_ADVISORY") == "1"

# ── loop guard ───────────────────────────────────────────────────────────────
# A blocked plan goes back to the model, which revises and calls ExitPlanMode
# again. If the revision does not satisfy the gate, that is a loop with no exit:
# the user never sees a plan and the session burns. One block per distinct
# problem-set; a plan that changed in a way the gate still rejects gets its
# objection as CONTEXT instead, so the user gets to judge the plan themselves.
#
# This is the difference between a gate and a wall. The gate's job is to make
# sure the plan the user approves has been checked — not to hold the plan
# hostage until the model guesses the phrasing it wants.
import hashlib, tempfile

_sig = hashlib.sha1("|".join(sorted(problems)).encode()).hexdigest()[:16]
_guard = os.path.join(
    tempfile.gettempdir(),
    "serge-plan-%s.seen" % hashlib.sha1(
        str(d.get("session_id") or "nosid").encode()).hexdigest()[:12])
_prev = ""
try:
    with open(_guard) as fh:
        _prev = fh.read().strip()
except Exception:
    pass
if _prev == _sig:
    advisory = True                  # already objected to exactly this; do not wall
else:
    try:
        with open(_guard, "w") as fh:
            fh.write(_sig)
    except Exception:
        pass
label = {0: "T0 local", 1: "T1 small", 2: "T2 multi-module", 3: "T3 structural"}[tier]

body = ["Plan gate (%s, %d file(s) cited): %d issue(s) before this plan is worth approving."
        % (label, n_files, len(problems)), ""]
for i, p in enumerate(problems, 1):
    body.append("  %d. %s" % (i, p))
body += [
    "",
    "This fires BEFORE the user is asked to approve, so the plan they see has already "
    "been checked. Revise the plan and call ExitPlanMode again.",
    "The requirement is that the question was ANSWERED, never that extra infrastructure "
    "be built — 'not needed here because X' is a complete answer.",
]
text = "\n".join(body)

# A missing file citation is a GROUNDED failure — the filesystem answered, and
# the plan was written about code that does not exist. That blocks at any tier,
# including T1: tiering governs how much a plan must SAY, never whether it may
# be fiction. This is the check that catches confident-fictional planning, so
# letting a tier threshold suppress it would remove the point of the gate.
if missing and not advisory:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": text,
    }}))
    sys.exit(0)

if advisory or tier < min_tier:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": text,
    }}))
    sys.exit(0)

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": text,
}}))
sys.exit(0)
PY
