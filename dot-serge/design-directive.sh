#!/usr/bin/env bash
# UserPromptSubmit hook — inject the engineering lenses this task actually needs,
# BEFORE any code is written. Local CPU, no LLM call, $0.
#
# WHY. complexity-directive.sh already asks the cost question ("what is n, what
# container makes this O(1)"). It does not ask the STRUCTURAL ones: what holds
# this up, what happens at 10x, what breaks when it fails, who else has to
# understand it. Production software is maintainable, scalable, secure, tested,
# reliable and extensible by a team — none of which is decided at the keyboard.
# It is decided before the first line, and nothing in the always-on path asks.
#
# WHY ROUTED AND NOT ALWAYS-ON. Injecting every CS domain and every primitive on
# every task produces a wall the model skims, and makes Serge slower and worse at
# small work. The skill is routing: detect the shape of the task, inject only
# what bears on it. A task about an HTTP client gets networking and reliability;
# a schema task gets databases and rollback; a typo fix gets nothing.
#
# EACH LENS IS A QUESTION WITH A CHECKABLE ANSWER, never a heading to fill in.
# "Security: N/A" passes a checklist and answers nothing; "what does an attacker
# control here" cannot be answered without thinking.
#
# THE VOCABULARY blocks name the primitives a competent engineer reaches for in
# that domain. They are phrased as CHOICES, not definitions — the failure this
# addresses is not ignorance of what a hash map is, it is not stopping to ask
# whether this is a hash map problem.
#
# Discrete maths is not a routed lens: it is the substrate the answers are
# written in (invariants, termination, case exhaustiveness), so it rides inside
# the algorithm lens rather than as its own heading.
#
# Same benign-both-directions design as complexity-directive.sh: a false positive
# costs a few tokens and better habits, never wrong behaviour.
#
# Off-switch: SERGE_DESIGN_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_DESIGN_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import json, re, sys

_WRAPPERS = (r"<system-reminder>.*?</system-reminder>"
             r"|<task-notification>.*?</task-notification>"
             r"|\[SYSTEM NOTIFICATION[^\]]*\]")

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

prompt = re.sub(_WRAPPERS, " ", str(d.get("prompt") or ""), flags=re.S | re.I)
if not prompt.strip():
    sys.exit(0)
low = prompt.lower()

# ── what shape is this turn? ─────────────────────────────────────────────────
BUILD = re.compile(
    r"\b(build|implement|add|create|write|design|refactor|rewrite|port|migrate|"
    r"introduce|extend|wire|integrate|set ?up|architect|scaffold|optimi[sz]e)\b", re.I)
DEBUG = re.compile(
    r"\b(debug|bug|broken|failing|fails|crash|error|exception|regression|"
    r"why (?:is|does|isn'?t|doesn'?t)|not work|stack ?trace|traceback|flaky|hang|"
    r"leak|corrupt|wrong (?:output|result|value)|investigate)\b", re.I)
REFACTOR = re.compile(
    r"\b(refactor|clean ?up|simplify|tidy|restructure|extract|rename|deduplicate|"
    r"dedupe|consolidate|reduce|shrink|trim|tech(?:nical)? debt|legacy)\b", re.I)
NOT_BUILD = re.compile(
    r"^\s*(what|why is this|how does|how do|explain|show me|tell me|where is|who|when|"
    r"can you (?:explain|show|tell)|does )\b", re.I)
TRIVIAL = re.compile(r"\b(typo|whitespace|lint|format|bump|changelog|readme)\b", re.I)

is_debug = bool(DEBUG.search(prompt))
is_refactor = bool(REFACTOR.search(prompt))
is_build = bool(BUILD.search(prompt))

if TRIVIAL.search(prompt) and len(prompt) < 200:
    sys.exit(0)
if NOT_BUILD.search(prompt.strip()) and not (is_debug or is_refactor):
    sys.exit(0)
if not (is_build or is_debug or is_refactor):
    sys.exit(0)

# ── routing table: (trigger, lens, the question, the primitives to weigh) ────
LENSES = [
    (r"\b(loop|iterat|sort|search|collection|array|list|map|set|cache|index|"
     r"scale|scaling|throughput|latency|hot path|performance|slow|optimi[sz]|"
     r"batch|dedup|all the|every )\b",
     "A/B · Algorithms & data structures",
     "What is n, what complexity are you targeting, and which container makes the "
     "lookup O(1)? State the invariant, and why the loop terminates.",
     "array | linked list | set | stack | queue | hash map | tree | graph — pick on "
     "ACCESS PATTERN, not familiarity. Then: brute force, divide-and-conquer, greedy, "
     "dynamic programming + memoization, backtracking, or Dijkstra? Time AND space "
     "complexity, separately. Recursion needs a base condition and a call-stack "
     "budget — deep recursion is a stack overflow waiting for production data."),

    (r"\b(module|service|interface|abstraction|layer|boundary|class|package|"
     r"component|plugin|architecture|inherit|polymorph)\b",
     "C · Paradigms & boundaries",
     "Where does the boundary sit, what crosses it, what state is mutable, and why "
     "this paradigm? Which direction do dependencies point — and does anything point back?",
     "imperative/procedural vs OOP (class, properties, methods, inheritance, "
     "instantiation) vs functional vs declarative — most languages are multiparadigm, "
     "so choose per problem. Reach for a design pattern only when it removes more "
     "complexity than it adds. Inheritance is the most over-used tool in this list."),

    (r"\b(memory|allocat|buffer|stream|large file|payload|copy|clone|pointer|"
     r"cpu|thread|concurren|parallel|worker|byte|encod|binary|hex)\b",
     "D · Machine reality",
     "What is allocated per request, what is copied, and is this I/O-bound or "
     "CPU-bound? What is the ceiling before it stops fitting?",
     "bit, byte, nibble, hex; signed vs unsigned; int vs float vs double (floats do "
     "not compare equal); char vs string and the encoding (ASCII vs UTF-8); "
     "endianness when bytes cross a boundary. Stack vs heap, references vs values, "
     "and whether a garbage collector is doing work you are paying for. "
     "Concurrency (interleaved) is not parallelism (simultaneous) — say which you need."),

    (r"\b(http|https|api|endpoint|request|fetch|socket|websocket|grpc|queue|"
     r"webhook|remote|upstream|downstream|network|client|server|dns|url|tcp|ssl|tls)\b",
     "E · Networking & failure",
     "Timeout, retry policy, and idempotency — and what happens on PARTIAL failure? "
     "A retried non-idempotent write is a data-corruption bug.",
     "URL → DNS → IP → TCP → TLS/SSL → HTTP: know which layer your failure is at "
     "before fixing it. Packets fragment, connections half-open, DNS caches lie. "
     "An API is a contract: version it, and decide what a breaking change means."),

    (r"\b(database|db|schema|migration|migrate|table|column|query|sql|index|"
     r"transaction|persist|store|orm|record|row)\b",
     "F · Data & persistence",
     "Which index serves this query, where is the transaction boundary, what is the "
     "rollback, and what does the backfill cost on real data volume?",
     "A table is a data structure with a disk budget: the index IS the tree you would "
     "have built in memory. Normalize until it hurts, denormalize until it works. "
     "Every migration needs its inverse before it ships."),

    (r"\b(auth|authz|authent|login|token|jwt|session|password|secret|credential|"
     r"encrypt|hash|pii|permission|role|upload|user input|sanitiz|escape|ssl)\b",
     "H5 · Security",
     "What does an attacker control, where is the trust boundary, and what is the "
     "least privilege that still works? Name the threat, not the mitigation.",
     "Hashing is not encryption. Validate on the trusted side of the boundary. "
     "Anything the client sends is attacker-controlled, including headers. "
     "Secrets belong in the environment, never in the tree."),

    (r"\b(model|prompt|inference|embedding|llm|ai |ml |eval|fine-?tun|token cost|"
     r"completion|agent)\b",
     "H1 · AI/ML",
     "How is this evaluated, where does the data come from, and what does one call "
     "cost? An eval that cannot fail measures nothing.", None),

    (r"\b(deploy|container|docker|kubernetes|k8s|region|edge|cdn|serverless|"
     r"lambda|infra|terraform|ci/cd|pipeline|vm|bare metal|kernel|ssh)\b",
     "H3 · Cloud, edge & operations",
     "What is observable when this misbehaves at 3am, what are its resource limits, "
     "and what is its failure domain?",
     "bare metal vs VM vs container: each layer trades isolation for overhead. "
     "The kernel mediates every I/O you do — a syscall is not free."),

    (r"\b(metric|analytic|aggregate|report|dashboard|track|measure|statistic|sample)\b",
     "H4 · Data science",
     "Does this metric actually measure the thing you will claim it measures? "
     "What biases the sample?", None),

    (r"\b(blockchain|ledger|consensus|wallet|smart contract|on-?chain)\b",
     "H2 · Distributed ledger",
     "Why does this need consensus rather than a database? State the trust model.", None),
]

hits = [(n, q, v) for pat, n, q, v in LENSES if re.search(pat, low, re.I)]

# ── vocabulary ───────────────────────────────────────────────────────────────
# The primitives, DEFINED, with what each one costs you. Loaded from data rather
# than inlined so the definitions can be edited without touching this logic, and
# so a human can read the whole reference in one place.
#
# Bounded on purpose: a full dump of 84 terms on every build turn is a wall the
# model skims, which teaches it to skim the whole directive. Terms whose name
# appears in the prompt come first, then the rest of the cluster, capped.
VOCAB_FOR = {
    "A/B · Algorithms & data structures": ["struct", "algo"],
    "C · Paradigms & boundaries":         ["lang"],
    "D · Machine reality":                ["machine"],
    "E · Networking & failure":           ["net"],
    "H3 · Cloud, edge & operations":      ["system"],
}
VOCAB_CAP = 14

import os

# This script is fed to python on STDIN, so __file__ does not exist — resolving
# the data file relative to it silently yielded nothing and the table vanished
# without an error. Resolve from the active config dir instead, the same way
# arch-gate.sh locates archscan.py.
_HOME = (os.environ.get("SERGE_VOCAB_DIR")
         or os.environ.get("SERGE_HOME")
         or os.environ.get("CLAUDE_CONFIG_DIR")
         or os.path.join(os.path.expanduser("~"), ".serge"))
_VOCAB_PATH = os.path.join(_HOME, "lib", "cs-vocab.json")
_VOCAB_CACHE = {}


def vocab_for(lens_name):
    if not _VOCAB_CACHE:
        try:
            with open(_VOCAB_PATH, encoding="utf-8") as fh:
                _VOCAB_CACHE.update(json.load(fh))
        except Exception:
            _VOCAB_CACHE["__missing__"] = True
    data = _VOCAB_CACHE
    if data.get("__missing__"):
        return []                       # no reference file — say nothing rather than guess
    picked = []
    for key in VOCAB_FOR.get(lens_name, []):
        picked.extend(data.get(key, {}).get("terms", []))
    if not picked:
        return []
    # Mentioned terms first: if the prompt already says "hash map", the model is
    # thinking about it and the definition is worth its lines.
    named = [t for t in picked if t["t"].split(" / ")[0].lower() in low]
    rest = [t for t in picked if t not in named]
    return (named + rest)[:VOCAB_CAP]

out = ["**Engineering discipline — before writing code.**", ""]

# ── mode-specific opening ────────────────────────────────────────────────────
# WHY debugging and refactoring get their own weight: a more productive agent
# writes more code per turn, and more code per turn is more defects and more
# structure to keep coherent. Volume without the corresponding rise in
# diagnosis and consolidation is how a codebase becomes a fast-moving beta.
if is_debug:
    out += [
        "This turn is a DIAGNOSIS. Diagnosis is not editing until the symptom stops.",
        "",
        "- **Reproduce first.** A bug you cannot trigger on demand cannot be confirmed fixed.",
        "- **Read the actual error.** The stack trace names a file and a line; start there, "
        "not at the place you assume is wrong.",
        "- **Form ONE hypothesis and a test that would DISPROVE it.** A hypothesis that "
        "survives only because you never tried to break it is a guess.",
        "- **Bisect.** Halve the search space each step — the codebase, the input, the "
        "commit range. Linear scanning of a large surface is how a turn runs out.",
        "- **Find the CAUSE, not the site.** The line that throws is often the first place "
        "a bad value became visible, not where it was produced.",
        "- **Then fix, and add the test that would have caught it.** A fix with no "
        "regression test is a fix that comes back.",
        "",
    ]
if is_refactor:
    out += [
        "This turn is a REFACTOR: behaviour must be IDENTICAL afterwards.",
        "",
        "- **Characterize first.** If tests do not pin the current behaviour, you are not "
        "refactoring, you are rewriting and hoping.",
        "- **Separate the moves.** A behaviour change inside a rename is invisible in review.",
        "- **Refactor toward a named force** — remove duplication, invert a dependency, "
        "narrow an interface. \"Cleaner\" is not a goal, it is an opinion.",
        "- **It must come out SMALLER.** A refactor that adds lines needs to say what it "
        "bought with them.",
        "",
    ]

# ── always-on structural questions ───────────────────────────────────────────
out += [
    "- **Load-bearing structure.** What holds this up? Name the one piece that, if "
    "wrong, makes everything above it wrong — and decide that piece first.",
    "- **10x.** What breaks when this serves ten times the load or the data? "
    "Deciding \"n stays small, this is fine\" IS an answer; not having thought about "
    "it is not.",
    "- **Failure.** What happens when it fails — not if. What does the caller see, and "
    "what state is left behind?",
    "- **The next person.** What will someone reading this in six months need that is "
    "not obvious from the code? That goes in a comment now, not later.",
    "- **Verification.** How will you KNOW it works? Name the check before you write "
    "the code — a check invented afterwards tends to be one the code passes.",
]

# ── density ──────────────────────────────────────────────────────────────────
# Model-written code is measurably bulkier than human code for the same
# behaviour, and bulk is not free: it is more to read, more to keep true, and
# more places for the next change to go wrong. arch-gate measures the removable
# fraction and blocks past a threshold, so this is a target, not a preference.
out += [
    "",
    "**Density.** Write it at roughly two-thirds the length you would have. Concretely, "
    "before you finish, delete:",
    "- comments that restate the line below them",
    "- variables assigned once and used once — inline them",
    "- `else` after a `return`/`throw`/`continue`, and `if (x) return true; else return false`",
    "- wrappers that forward their arguments unchanged, and `try/catch` that only rethrows",
    "- the second copy of any block you wrote twice — extract it or drop it",
    "- defensive checks for conditions that cannot occur here",
    "",
    "Comments earn their place by saying WHY, never WHAT. `arch-gate` measures the "
    "removable fraction of what you write and blocks past it, so this is checked, not asked.",
]

if hits:
    out += ["", "**Lenses this task specifically needs:**", ""]
    for name, q, vocab in hits[:5]:
        out.append("- **%s** — %s" % (name, q))
        if vocab:
            out.append("  - *Weigh:* %s" % vocab)
        terms = vocab_for(name)
        if terms:
            out.append("")
            out.append("  | term | what it is | when it matters |")
            out.append("  |---|---|---|")
            for t in terms:
                out.append("  | `%s` | %s | %s |" % (t["t"], t["d"], t["u"]))
            out.append("")

out += [
    "",
    "Answer these in the plan, briefly. \"Not needed here because X\" is a complete "
    "answer — the requirement is that it was decided, never that extra infrastructure "
    "gets built (RULES.md: YAGNI, no enterprise bloat). Architecture is then checked "
    "mechanically on every edit by arch-gate.sh: cycles, orphan and self-referential "
    "modules, layering violations, swallowed errors, unbounded resources, N+1s, missing "
    "rollback, assertion-free tests and removable bulk are COMPUTED, not asked about.",
]

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "\n".join(out),
}}))
PY
