#!/usr/bin/env bash
# Serge UserPromptSubmit hook — silent-ambiguity decision-procedure directive ($0, no LLM).
#
# WHY: serge's constitution (behavior/decoding_intent) already describes the right
# 3-branch procedure for ambiguous requests — resolve from evidence → proceed+state /
# ask-one-question-if-irreversible. But the routing/consult classifiers only fire on
# EXPLICITLY-flagged uncertainty ("not sure", "how should I…"). Confident-sounding but
# UNDERSPECIFIED imperatives — "clean this up", "make it friendlier", "delete the config
# we're not using" — match NEITHER regex, so the weak workhorse gets no help and fails in
# one of three measured ways (evals 15/16/17, 2026-07-21):
#   15  silent guess   — proceeded on a divergent reading, never STATED it
#   16  under-ask      — deleted a file outright on a genuinely divergent, irreversible target
#   17  over-ask       — asked a vague question instead of resolving from the one obvious file
# All three are execution failures of a procedure the model already has the prose for.
#
# FIX: when the prompt shows a silent-ambiguity signature, inject the decoding_intent
# decision procedure as a <system-reminder> so the procedure is in front of the model AT
# the decision point. Benign in both directions — it discourages BOTH reflexive asking and
# silent guessing — so a false positive costs only a few tokens, never wrong behavior.
#
# Fires only on ACTION-shaped ambiguity (vague transformation verb, irreversible-verb +
# vague target, or a bare deictic object). Fully-specified requests ("change `a - b` to
# `a + b`") do not match. Complements research-directive.sh + auto-consult.sh.
#
# Off-switch: SERGE_AMBIGUITY_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_AMBIGUITY_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

# Harness plumbing is not a user turn. Strip <system-reminder> AND <task-notification>
# blocks (background-task completions arrive through UserPromptSubmit): 13 of 45 consults on
# 2026-07-21 fired on task notifications — wasted free-tier quota and added latency before
# every background completion. If nothing user-authored remains, this is not a turn to act on.
_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

prompt = str(d.get("prompt") or "")
# Key on the user's words: drop harness-injected reminders, skip slash-commands / huge pastes.
clean = re.sub(_WRAPPERS, " ", prompt, flags=re.S).strip()
if not clean or clean.startswith("/") or len(clean) > 8000:
    sys.exit(0)

# --- ambiguity signatures ---------------------------------------------------
# G1: vague, open-ended transformation ("make it better" class).
VAGUE_ACTION = re.compile(r"""
  \b(
      clean\s+(?:this|it|these|those|that|them)?\s*up
    | clean\s+up
    | tidy(?:\s+up)?
    | refactor
    | polish
    | improve
    | optimi[sz]e
    | moderni[sz]e
    | streamline
    | make\s+\S[^.\n]{0,40}?\b(?:better|nicer|cleaner|friendlier|prettier|simpler|faster|safer|clearer|smoother|more\s+\w+)\b
    | fix\s+(?:this|it|that|the\s+thing|the\s+issue|the\s+problem|the\s+bug|the\s+error)\b
    | handle\s+(?:this|it|that|the\s+\w+)\b
    | sort\s+(?:this|it|that|them)?\s*out
    | deal\s+with\s+(?:this|it|that|the)\b
  )
""", re.I | re.X)

# G2: irreversible/destructive verb aimed at a vaguely-qualified target — the highest-risk
# class (a wrong guess is unrecoverable). Requires the destructive verb AND a vague qualifier.
IRREVERSIBLE_VAGUE = re.compile(r"""
  \b(?:delete|remove|drop|wipe|clear|reset|overwrite|purge|nuke|truncate|revert|rm)\b
  [^.\n]{0,60}?
  \b(?:the|old|unused|stale|extra|duplicate|duplicated|redundant|obsolete|leftover|dead|
       that|those|these|unnecessary|useless|not\s+used|no\s+longer|
       (?:we'?re|we\s+are|i'?m)\s+not\s+using)\b
""", re.I | re.X)

# G3: a bare deictic object standing in for an unnamed thing.
DEICTIC = re.compile(r"""
  \b(?:update|change|edit|rewrite|redo|adjust|tweak|revise|finish|complete|do|move)\s+
    (?:this|that|it|these|those|the\s+thing|the\s+stuff)\b
""", re.I | re.X)

# G4 (A.3, 2026-07-21): fresh-start scope-bomb — no destructive VERB, so G2
# misses it, but the blast radius is unbounded ("start fresh" of WHAT? is the
# data/config/history preserved?). A wrong scope guess destroys work.
FRESH_START = re.compile(r"""
  \b(?:
      start\s+(?:over|fresh|again|clean|anew)
    | from\s+scratch
    | redo\s+(?:everything|the\s+whole|it\s+all|all\s+of)
    | rewrite\s+the\s+whole
    | blow\s+(?:it|this|that)\s+away
    | scrap\s+(?:it|this|that|everything)
    | throw\s+(?:it|this|that)\s+(?:away|out)
  )\b
""", re.I | re.X)

# G5 (A.3): bare failure report — symptom deixis with nothing identified
# ("it's broken", "still not working"). The measured failure mode is guessing
# a diagnosis from vibes instead of reproducing first.
BARE_FAILURE = re.compile(r"""
  \b(?:
      (?:it|this|that|the\s+\w+)(?:\s+is|'s)?\s+(?:broken|not\s+working|failing|busted)
    | (?:doesn'?t|does\s+not|won'?t|will\s+not)\s+(?:work|load|start|run|build|open|respond)
    | still\s+(?:broken|failing|not\s+working|doesn'?t\s+work|the\s+same)
    | same\s+(?:error|problem|issue|bug)(?:\s+again)?
    | nothing\s+(?:happens|loads|shows|works)
  )\b
""", re.I | re.X)

# G6 (2026-07-22): the request READS specific but names nothing selectable —
# a comparative with no stated baseline ("use the cheaper one", "make the
# watchdog stricter") or a change-verb aimed at a bare category noun ("swap the
# model"). Measured that day: G1-G5 all no-op on this class, because nothing in
# it is lexically vague — yet it is where the user actually gets bitten, since
# the model fills the missing referent from MEMORY (prior sessions' conclusions
# load every turn) instead of from the live request. That substitution is the
# reported complaint: "does something else from memory or assuming".
COMPARATIVE_BARE = re.compile(r"""
  (?:
      \b(?:the|a|some|something|anything|any)\s+(?:\w+\s+){0,2}
        (?:cheap|fast|slow|good|bad|strict|loose|tight|simple|small|big|large|new|old|
           safe|lean|strong|weak|light|quick|clean)(?:er|est)\b
    | \bmake\s+(?:it|this|that|them|the\s+\w+|\w+)\s+
        (?:\w+\s+)?(?:cheap|fast|slow|strict|loose|tight|simple|small|big|large|new|
                     safe|lean|strong|weak|light|quick|clean)(?:er|est)\b
    | \b(?:more|less)\s+\w+\s+(?:one|option|version|model|seat)\b
    | \b(?:use|switch\s+to|go\s+with|pick|choose|prefer)\s+the\s+
        (?:\w+\s+){0,2}(?:one|option)\b
  )
""", re.I | re.X)

# A change verb pointed at a bare CATEGORY noun — the category has many members
# and none is named ("swap the model", "bump the cap", "change the key").
BARE_SLOT = re.compile(r"""
    # direct object: "swap the model", "bump the cap"
    \b(?:use|swap|switch|change|replace|move|put|point|set|bump|raise|lower|drop|
         disable|enable|tweak|adjust|repoint|retarget)\b
    \s+(?:out\s+|over\s+|it\s+)?(?:the|our|that)\s+
    (?:model|seat|rung|key|config|setting|provider|agent|hook|skill|loop|cap|limit|
       threshold|timeout|endpoint|prompt|script|service|file|one|thing)\b
    # ...or behind a preposition: "put the reviewer ON THE FREE SEAT",
    # "route the brain to the cheap rung". The destination is the unnamed part.
  | \b(?:use|swap|switch|change|replace|move|put|point|set|repoint|retarget|route|
         send|run)\b
    [^.\n]{0,40}?\b(?:on|onto|to|at|for|with)\s+(?:the|our|a)\s+(?:\w+\s+){0,2}
    (?:model|seat|rung|key|config|provider|agent|hook|skill|loop|cap|limit|
       endpoint|one)\b
""", re.I | re.X)

# Suppressor: if the request already names something concrete — a backticked
# token, a path, a filename, an ALL_CAPS constant, a quoted string, or a
# hyphenated seat name (haiku-paid, free-flash) — then it is SPECIFIED and G6
# must stay quiet. This is what keeps G6 from firing on ordinary work; G1-G5
# are deliberately NOT gated by it, so existing behavior is unchanged.
SPECIFIC_TOKEN = re.compile(r"""
    `[^`]+`
  | "[^"]{2,}"
  | \b[A-Z][A-Z0-9_]{3,}\b
  | \b[\w.-]+\.(?:py|sh|ts|tsx|js|jsx|yaml|yml|json|md|toml|conf|env)\b
  | /[\w./-]{4,}
  | \b\w+-(?:paid|coder|brain|flash|scout|large|qwen|flash3|flash25)\b
""", re.X)

# G7: unresolved REFERENT with no action verb. G3/DEICTIC requires a verb ("update
# this", "change that"), so a purely referential turn — "yes that and the other",
# "do the first one" — matches nothing and the turn gets no framing at all. Rare
# (~0.4% of turns measured over a real prompt corpus) but it is precisely the case
# the constitution's decoding-intent section has doctrine for — resolving referents
# from the conversation rather than the words — with no hook putting that procedure
# in front of the model at the decision point. Gated by SPECIFIC_TOKEN like G6, and
# by PLUMBING because the harness's own retry/continuation messages ("the previous
# turn was terminated") are not user turns and matched 7 of 10 hits in an
# untightened draft of this pattern.
BARE_REFERENT = re.compile(r"""
    \b(?:the|that)\s+(?:other|first|second|last|latter|former)(?:\s+one)?\b
  | \b(?:that|this)\s+one\b
  | \bthe\s+one\s+(?:we|you|i|they)\b
""", re.I | re.X)

PLUMBING = re.compile(
    r"previous turn was terminated|transient API failure|Stop hook feedback"
    r"|session is being continued", re.I)

hit_g4 = bool(FRESH_START.search(clean))
hit_g5 = bool(BARE_FAILURE.search(clean))
hit_g6 = bool(
    (COMPARATIVE_BARE.search(clean) or BARE_SLOT.search(clean))
    and not SPECIFIC_TOKEN.search(clean)
)
hit_g7 = bool(
    BARE_REFERENT.search(clean)
    and not SPECIFIC_TOKEN.search(clean)
    and not PLUMBING.search(clean)
)
if not (VAGUE_ACTION.search(clean) or IRREVERSIBLE_VAGUE.search(clean)
        or DEICTIC.search(clean) or hit_g4 or hit_g5 or hit_g6 or hit_g7):
    sys.exit(0)

ctx = (
    "<system-reminder>\n"
    "This request is underspecified. Decode the intent before acting:\n"
    "1. RESOLVE IT FROM EVIDENCE FIRST — look at the repo, the named or obvious file(s), "
    "git history, and memory before you ask or guess. A vague ask ('clean this up') usually "
    "has one obvious target; find it and turn the request into concrete criteria the user "
    "can correct — don't reflexively ask when the evidence resolves it.\n"
    "2. NON-DESTRUCTIVE + a reading that is cheap to reverse -> proceed on the single best "
    "reading and STATE that reading in one line, so a wrong guess costs one correction.\n"
    "3. IRREVERSIBLE actions (delete, remove, overwrite, drop, reset, truncate, migrate, "
    "deploy, force-push) — a HARD rule that overrides your own judgment: if the target is named "
    "only by DESCRIPTION ('the old one', 'the unused config', 'the one we're not using') rather "
    "than an exact name, OR if anything hints a candidate might still be wanted (a TODO, a "
    "comment, a 'may switch to' note, any reference), you MUST ask ONE precise question naming "
    "the candidates BEFORE acting. Do NOT rationalize a hint away as 'just a comment' or "
    "'probably fine' and proceed — inference is NOT sufficient to justify an unrecoverable "
    "action. Skip the question only when the target is named exactly AND nothing contradicts it.\n"
)
if hit_g4:
    ctx += (
        "4. FRESH-START SCOPE: 'start over / from scratch / redo everything' has an unbounded "
        "blast radius. Before destroying or replacing anything, state exactly WHAT gets "
        "recreated and what is PRESERVED (data, config, history, working code) in one line; "
        "if the scope genuinely forks (this file? this feature? the whole project?), ask ONE "
        "question naming the readings instead of guessing.\n"
    )
if hit_g5:
    ctx += (
        "5. BARE FAILURE REPORT: 'it's broken / still not working' is a symptom, not a "
        "diagnosis. REPRODUCE the failure first — drive the real surface, capture the actual "
        "error/output — and name what you observed before changing any code. Do not guess a "
        "cause from the phrasing, and do not re-apply the previous fix harder.\n"
    )
if hit_g6:
    ctx += (
        "6. UNNAMED REFERENT / UNSTATED BASELINE: this request sounds specific but does not "
        "name the thing it acts on ('the cheaper one', 'the model', 'stricter'). NAME THE "
        "REAL CANDIDATES IN THIS REPLY, by their actual identifiers from the current state. "
        "If the relevant content is already in front of you, that naming IS the next step — "
        "do NOT answer with an announcement that you will go look ('I'll read the config to "
        "identify it'); that defers the decision instead of making it. Never let a remembered "
        "answer from an earlier session stand in for the referent: memory tells you what WAS "
        "true, not what the user means this time, and a name that does not appear in the "
        "current state is a guess. CURRENT STATE OUTRANKS MEMORY, including remembered "
        "PROHIBITIONS: if a note says an option was removed, banned, or is unusable, but the "
        "file in front of you still shows it, the file wins — treat the note as stale, say in "
        "one line that you are setting it aside and why, and do not silently narrow your "
        "options to obey it. A remembered constraint that current state contradicts is a "
        "reason to FLAG the conflict, never a reason to quietly exclude a candidate. "
        "If a comparative has no baseline ('stricter' than what? "
        "'cheaper' than what?), state the baseline you are using in one line. If two or more "
        "candidates fit equally, name them and ask ONE question. Do NOT dodge the choice by "
        "applying the change to every candidate at once — that is not a resolution.\n"
    )
if hit_g7:
    ctx += (
        "7. UNRESOLVED REFERENT: this turn points at something ('the other', 'that one', "
        "'the first one') without naming it, and the referent lives in the CONVERSATION, not "
        "in the words. Resolve it before acting: re-read what was actually proposed, listed, "
        "or offered in the preceding turns and say in one line WHICH item you are taking it "
        "to mean. If the prior turn offered several things and this reply accepts some of "
        "them, enumerate the ones you are acting on. If the referent genuinely does not "
        "resolve against anything on record, ask ONE question naming the candidates — do not "
        "invent a plausible target, and do not answer a different question than the one the "
        "referent points at.\n"
    )
ctx += "</system-reminder>"
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
