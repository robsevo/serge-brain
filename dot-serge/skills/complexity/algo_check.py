#!/usr/bin/env python3
"""algo_check — deterministic cost + correctness analyzer for backend code.

Why this exists (the two measured LLM failure modes this closes):

  1. CORRECTNESS. Model-written code carries materially more defects than
     human-written code, and the excess is concentrated in SUBTLE slips that
     compile and read fine: `>` where `>=` belongs, `<= arr.length`, an index
     shifted by one, a loop that never advances, a guard that swallows the
     error it was supposed to raise. Reviewers skim past them because the code
     LOOKS right. `bounds` finds this class mechanically instead of by eye —
     including the flagship differential check: the same operand pair compared
     with `>` in one place and `>=` in another is the exact shape of a dropped
     `=`, and no single line looks wrong on its own.

  2. VOLUME. Model-written code is substantially bulkier than an engineer's for
     the same behavior, and bulk is not free: it is extra passes, extra copies,
     extra allocations, dead branches, and re-derived work inside loops. `bigo`
     prices the algorithm (nesting, hidden linear scans, N+1 I/O, serial awaits,
     quadratic accumulation) and `fluff` prices the dead weight in LINES, so
     "this is bloated" becomes a number instead of an opinion.

The design rule is the same one `logic_check.py` is built on: a model must not
adjudicate this by inspection. It writes the code; the tool prices it.

Usage:
  algo_check.py bigo   <file>...      # per-function complexity + the hot paths
  algo_check.py bounds <file>...      # off-by-one / operator-slip / boundary bugs
  algo_check.py fluff  <file>...      # dead weight, in removable lines
  algo_check.py all    <file>...      # everything, one report

Pass several files in one run and the analysis gets SHARPER, never wronger: costs
propagate across the call graph, so a linear helper in one file called inside a loop
in another is priced as the O(n²) it is. A name defined twice in the set does not
resolve at all — guessing which was meant would invent a complexity, not measure one.

Options:
  --lines A-B,C-D   only report findings inside these line ranges, and only for the
                    FIRST file given — any others are context for call resolution.
                    (The edit gate uses this so legacy code never nags: you own what
                    you touched, but a call out of it still resolves.)
  --min-sev S       certain | high | medium | low   (default: medium)
  --json            machine-readable findings + volume summary
  --quiet           print nothing; exit code carries the verdict
  --no-context      do not auto-load sibling files (findings become file-local)

Exit codes: 0 = clean at/above --min-sev, 2 = findings, 1 = bad usage.

Languages: .py via the real `ast`; .js/.jsx/.ts/.tsx/.mjs/.cjs via a
comment/string/template/regex-aware masker + brace-structure walker. Stdlib
only, no network, no install. Anything else is skipped silently.

HONESTY: complexity here is a SYNTACTIC estimate over loop structure and known
container costs, not a proof. Every verdict prints the evidence that produced
it (which line contributed which factor) so it can be checked in one read. An
estimate you can audit beats a confident number you cannot.
"""
import ast
import json
import os
import re
import sys

SEV_ORDER = {"low": 0, "medium": 1, "high": 2, "certain": 3}
SRC_EXT = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
MAX_BYTES = 1_500_000
AUTO_CONTEXT_CAP = 40      # sibling files auto-loaded to resolve calls

# ─────────────────────────────────────────────────────────────── findings ───


class F:
    """One finding. `fix` is the actionable half — a finding without a move is a nag."""

    __slots__ = ("path", "line", "kind", "sev", "msg", "fix", "cost")

    def __init__(self, path, line, kind, sev, msg, fix="", cost=0):
        self.path, self.line, self.kind, self.sev = path, line, kind, sev
        self.msg, self.fix, self.cost = msg, fix, cost   # cost = removable lines

    def as_dict(self):
        return {"path": self.path, "line": self.line, "kind": self.kind,
                "sev": self.sev, "msg": self.msg, "fix": self.fix, "cost": self.cost}


# ────────────────────────────────────────────────────── complexity algebra ───
# A complexity is (poly, log, exp): n**poly * (log n)**log, or 2**n when exp.
# Composition is multiplication; alternatives take the max. Small enough to be
# obviously correct, expressive enough for every shape that shows up in a
# service: constant, log, linear, linearithmic, polynomial, exponential.

CONST, LOGN, LIN = (0, 0, False), (0, 1, False), (1, 0, False)


def cx_mul(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] or b[2])


def cx_max(a, b):
    if a[2] != b[2]:
        return a if a[2] else b
    return a if (a[0], a[1]) >= (b[0], b[1]) else b


def cx_str(c):
    if c[2]:
        return "O(2^n)"
    p, l = c[0], c[1]
    if p == 0 and l == 0:
        return "O(1)"
    # Past n⁴ the exact exponent is beyond what a syntactic estimate can defend —
    # publishing "O(n^6)" invites a rebuttal about the number instead of a look at
    # the nesting, which IS the finding. Say "at least", and mean it.
    if p >= 5:
        return "O(n⁵ or worse)"
    sup = {2: "²", 3: "³", 4: "⁴", 5: "⁵"}
    base = "" if p == 0 else ("n" if p == 1 else "n" + sup.get(p, "^%d" % p))
    lg = "" if l == 0 else ("log n" if l == 1 else "(log n)^%d" % l)
    return "O(" + (base + (" " if base and lg else "") + lg) + ")"


MAX_DEGREE = 6          # runaway guard for call-graph cycles


class FnInfo:
    """One function's cost, before and after interprocedural propagation.

    `self_cost` is what the function's own loops cost. `total` adds what it costs
    through the functions it CALLS — because a linear helper called inside a loop is
    O(n²) while neither function is quadratic on its own, which is exactly the shape
    a per-function reading (human or model) misses.
    """

    __slots__ = ("path", "key", "name", "line", "self_cost", "chain", "fix",
                 "calls", "total", "via", "worst_line")

    def __init__(self, path, key, name, line):
        self.path, self.key, self.name, self.line = path, key, name, line
        self.self_cost = self.total = CONST
        self.chain = self.fix = self.via = ""
        self.calls = []                 # (callee_name, factor_at_site, call_line)
        self.worst_line = line


def propagate(fns):
    """Fixed-point over the call graph. Conservative by construction: a name defined
    more than once across the analysed set does not resolve at all, because guessing
    which definition was meant would invent a complexity rather than measure one."""
    by_name = {}
    for f in fns:
        by_name.setdefault(f.name, []).append(f)
    uniq = {n: v[0] for n, v in by_name.items()
            if len(v) == 1 and n not in ("(anonymous)", "(top level)")}

    for _ in range(10):                 # converges in ≤ depth rounds; cap for cycles
        changed = False
        for f in fns:
            best, via = f.total, f.via
            for callee, factor, cline in f.calls:
                # ONLY calls inside a loop create new cost. A call made once already
                # has a finding at the callee's own site, and propagating it would
                # report every caller in the transitive closure instead of the one
                # place the cost is created — measured: it turned 1196 findings into
                # 4550, cascading to a meaningless "O(n^6)". The actionable finding
                # is where the LOOP is.
                if factor == CONST:
                    continue
                g = uniq.get(callee)
                if g is None or g is f:
                    continue
                cand = cx_mul(factor, g.total)
                if cand[0] > MAX_DEGREE:
                    cand = (MAX_DEGREE, cand[1], cand[2])
                merged = cx_max(best, cand)
                if merged != best:
                    best = merged
                    via = "calls `%s()`@%d which is %s" % (callee, cline, cx_str(g.total))
            if best != f.total:
                f.total, f.via, changed = best, via, True
        if not changed:
            break
    return fns


def bigo_findings(fns):
    out = []
    for f in fns:
        if f.total[0] + (2 if f.total[2] else 0) < 2:
            continue
        chain = " × ".join(p for p in (f.chain, f.via) if p)
        fix = f.fix
        if f.via and not fix:
            fix = ("hoist the call out of the loop, or make the callee O(1) by "
                   "pre-indexing what it scans — the cost is the loop times the callee")
        # A recognised 2-D table fill is at its lower bound — worth SAYING, not worth
        # blocking a turn over. `medium` keeps it out of the edit gate (which blocks at
        # high) while it still shows on a manual run.
        sev = "medium" if fix == INHERENT_FIX and not f.via else "high"
        out.append(F(f.path, f.worst_line, "bigo", sev,
                     "%s — est. %s  [%s]" % (f.name, cx_str(f.total), chain or "nested iteration"),
                     fix or "flatten the nesting, or pre-index the inner collection"))
    return out


# Body operations that cost more than O(1) per iteration, plus what to do instead.
OPS = {
    "scan":    (LIN,       "high",    "linear scan inside a loop",
                "hoist the collection into a dict/set/Map keyed by the lookup field, then look up in O(1)"),
    "sort":    ((1, 1, False), "high", "sort inside a loop",
                "sort once before the loop; a sort per iteration is the loop cost times n log n"),
    "concat":  (LIN,       "high",    "copying accumulation inside a loop",
                "push/append into one array and join once — spread/concat per iteration rebuilds the whole result each time"),
    "shift":   (LIN,       "high",    "front insert/remove on an array inside a loop",
                "use a deque (Python) or an index cursor / reversed pop — shift/pop(0) re-indexes every element"),
    "copy":    (LIN,       "medium",  "deep copy inside a loop",
                "copy once outside the loop, or mutate a purpose-built accumulator"),
    "regex":   (CONST,     "medium",  "regex compiled inside a loop",
                "compile the pattern once at module/function scope"),
    "io":      (CONST,     "high",    "I/O or a query inside a loop (N+1)",
                "batch it: one query with an IN/join for all ids, or a bulk endpoint — N round trips is the latency, not the CPU"),
    "await":   (CONST,     "medium",  "await inside a loop (serial round trips)",
                "if the iterations are independent, Promise.all / asyncio.gather them (bounded concurrency); if they must be sequential, say so in a comment"),
}


# ───────────────────────────────────────────────────────────── JS/TS front ───

_JS_REGEX_OK_WORDS = {"return", "typeof", "instanceof", "in", "of", "new", "delete",
                      "void", "case", "do", "else", "yield", "await", "throw"}
_JS_KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "function", "else",
                "do", "try", "typeof", "new", "delete", "await", "yield", "case",
                "throw", "with", "super", "this", "constructor", "import", "export"}


def js_mask(src):
    """→ (masked, line_comments). Blanks comments and string/template/regex BODIES,
    preserving offsets and newlines.

    Everything downstream regexes over the masked text, so a `//` inside a URL
    string or a `for` inside a comment can never be mistaken for code. Template
    `${...}` holes are deliberately left visible — real expressions live there.

    Comments are captured HERE rather than re-found later: after masking, a real
    `//` comment and the blanked interior of `"https://x"` are indistinguishable,
    so any second pass would read that URL as a comment.
    """
    comments = []
    out = list(src)
    n = len(src)
    i = 0
    prev_ch = ""      # last significant char
    prev_word = ""    # last identifier, when the last significant char was one

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n:
            d = src[i + 1]
            if d == "/":
                j = src.find("\n", i)
                j = n if j < 0 else j
                comments.append((i, src[i + 2:j]))
                blank(i, j)
                i = j
                continue
            if d == "*":
                j = src.find("*/", i + 2)
                j = n if j < 0 else j + 2
                blank(i, j)
                i = j
                continue
            regex_ok = (prev_ch == "" or prev_ch in "(,=:[!&|?{};+-*%<>~^"
                        or prev_word in _JS_REGEX_OK_WORDS)
            if regex_ok:
                j, in_class = i + 1, False
                while j < n:
                    ch = src[j]
                    if ch == "\\":
                        j += 2
                        continue
                    if ch == "\n":
                        break
                    if ch == "[":
                        in_class = True
                    elif ch == "]":
                        in_class = False
                    elif ch == "/" and not in_class:
                        break
                    j += 1
                if j < n and src[j] == "/":
                    blank(i + 1, j)
                    j += 1
                    while j < n and src[j].isalpha():
                        j += 1
                    i, prev_ch, prev_word = j, "/", ""
                    continue
            prev_ch, prev_word = "/", ""
            i += 1
            continue

        if c in "'\"":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c or src[j] == "\n":
                    break
                j += 1
            blank(i + 1, j)
            i = min(j + 1, n)
            prev_ch, prev_word = '"', ""
            continue

        if c == "`":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "`":
                    break
                if src[j] == "$" and j + 1 < n and src[j + 1] == "{":
                    k, depth = j + 2, 1
                    while k < n and depth:
                        if src[k] == "{":
                            depth += 1
                        elif src[k] == "}":
                            depth -= 1
                        k += 1
                    j = k
                    continue
                if out[j] != "\n":
                    out[j] = " "
                j += 1
            i = min(j + 1, n)
            prev_ch, prev_word = "`", ""
            continue

        if c.isalnum() or c in "_$":
            j = i
            while j < n and (src[j].isalnum() or src[j] in "_$"):
                j += 1
            prev_word, prev_ch = src[i:j], src[j - 1]
            i = j
            continue

        if not c.isspace():
            prev_ch, prev_word = c, ""
        i += 1

    masked = "".join(out)
    starts = line_index(src)
    return masked, [(off_to_line(starts, off), text) for off, text in comments]


def line_index(src):
    """Offsets of each line start, for offset→line lookups."""
    starts, pos = [0], 0
    for ln in src.splitlines(True):
        pos += len(ln)
        starts.append(pos)
    return starts


def off_to_line(starts, off):
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= off:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1


def match_brace(masked, open_at):
    """Offset just past the `}` matching the `{` at open_at, or len on EOF."""
    depth, i, n = 0, open_at, len(masked)
    while i < n:
        c = masked[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def match_paren(masked, open_at):
    depth, i, n = 0, open_at, len(masked)
    while i < n:
        c = masked[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


class JsLoop:
    __slots__ = ("kind", "start", "body", "end", "line", "subject", "children", "method")

    def __init__(self, kind, start, body, end, line, subject, method=None):
        self.kind, self.start, self.body, self.end = kind, start, body, end
        self.line, self.subject, self.children, self.method = line, subject, [], method


_JS_LOOP_KW = re.compile(r"\b(for|while)\s*(?:await\s*)?\(")
# `sort` is deliberately NOT here: it is priced as an O(n log n) OPERATION below,
# not as a nested O(n) level — treating it as a loop under-counts it and produces
# a confusing evidence chain.
_JS_CB_LOOP = re.compile(r"\.\s*(forEach|map|filter|flatMap|reduce|reduceRight|some|every|find|findIndex)\s*\(")


def js_loops(masked, starts):
    """Every iteration construct with its body span. Callback iterators count —
    `.forEach` is a loop wearing a method's clothes, and nesting one inside a
    `for` is the same n² as nesting two `for`s."""
    loops = []
    for m in _JS_LOOP_KW.finditer(masked):
        p_end = match_paren(masked, m.end() - 1)
        head = masked[m.end():p_end - 1]
        j = p_end
        while j < len(masked) and masked[j].isspace():
            j += 1
        if j < len(masked) and masked[j] == "{":
            body, end = j, match_brace(masked, j)
        else:
            # Braceless body = exactly ONE statement, so it cannot outlive its line.
            # Scanning to the next `;` alone ran to wherever the next semicolon
            # happened to be (ASI-terminated code has none), which swallowed every
            # following sibling loop and reported them as nested — the source of
            # absurd exponents like O(n^38).
            k = masked.find(";", j)
            nl = masked.find("\n", j)
            if k < 0 or (0 <= nl < k):
                k = nl
            body, end = j, (len(masked) if k < 0 else k + 1)
        subj = js_loop_subject(head)
        loops.append(JsLoop(m.group(1), m.start(), body, end,
                            off_to_line(starts, m.start()), subj))
    for m in _JS_CB_LOOP.finditer(masked):
        p_end = match_paren(masked, m.end() - 1)
        loops.append(JsLoop("callback", m.start(), m.end(), p_end,
                            off_to_line(starts, m.start()),
                            js_recv(masked, m.start()), m.group(1)))
    loops.sort(key=lambda L: (L.start, -L.end))
    return loops


def js_recv(masked, dot_at):
    """The receiver immediately left of a `.method(` — the thing being iterated."""
    i = dot_at - 1
    while i >= 0 and masked[i].isspace():
        i -= 1
    end = i + 1
    while i >= 0 and (masked[i].isalnum() or masked[i] in "_$.[]"):
        i -= 1
    return masked[i + 1:end].strip() or "?"


_ARR_LIT = re.compile(r"^\s*\[[^\[\]]*\]\s*$")


def js_loop_subject(head):
    m = re.search(r"\b(?:of|in)\s+([A-Za-z_$][\w$.\[\]]*)", head)
    if m:
        return m.group(1)
    m = re.search(r"<=?\s*([A-Za-z_$][\w$.]*)\s*(?:\.length)?", head)
    if m:
        return m.group(1)
    return "?"


_CONST_ELEM = re.compile(r"""^\s*(?:'[^']*'|"[^"]*"|`[^`]*`|-?\d+(?:\.\d+)?|true|false|null)\s*$""")


def js_const_arrays(src):
    """Names bound to a literal array of literals — `const MODES = ['a','b','c']`.

    Iterating one is O(1), not O(n): the size is fixed at author time. Treating it as
    n turns every `for (m of MODES)` nested inside a data loop into a reported O(n²)
    that does not exist, which is how a checker teaches people to ignore it."""
    out = set()
    for m in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=;]+)?=\s*\[([^\[\]]*)\]", src):
        items = [i for i in m.group(2).split(",") if i.strip()]
        if items and len(items) <= 40 and all(_CONST_ELEM.match(i) for i in items):
            out.add(m.group(1))
    return out


def js_loop_size(masked, L, consts=frozenset()):
    """(complexity-of-one-level, why). A loop over a literal bound is not n."""
    if L.subject in consts:
        return CONST, "iterates a fixed literal array"
    if L.kind in ("for", "while"):
        p = masked.find("(", L.start)
        head = masked[p + 1:match_paren(masked, p) - 1]
        if re.search(r"[<>]=?\s*\d+\s*[;)]", head) and not re.search(r"\.length|\.size|\blen\(", head):
            return CONST, "fixed numeric bound"
        # halving / doubling ⇒ logarithmic
        if re.search(r"(>>=|<<=|/=\s*2|\*=\s*2|=\s*[\w$.]+\s*[/*]\s*2|Math\.floor\(\s*\(?[\w$.\s+]*\)?\s*/\s*2)",
                     masked[L.body:L.end]) or re.search(r"(>>=|/=\s*2|\*=\s*2)", head):
            return LOGN, "index halves/doubles each step"
    return LIN, "iterates a data-dependent collection"


# find/filter/some/every are priced as nested callback LOOPS (see _JS_CB_LOOP), so
# listing them here too would double-count the same scan.
_JS_SCAN = re.compile(r"\.\s*(includes|indexOf|lastIndexOf)\s*\(")
_JS_OBJ_SCAN = re.compile(r"\bObject\s*\.\s*(keys|values|entries|assign)\s*\(")
_JS_SORT = re.compile(r"\.\s*sort\s*\(")
# Quadratic accumulation is SELF-spread — rebuilding the accumulator each pass.
# Spreading the loop ELEMENT (`{...order, user}`) is O(1) per iteration and is the
# idiomatic way to write the O(n) version, so it must never be flagged.
_JS_SELF_SPREAD = re.compile(r"\b([A-Za-z_$][\w$]*)\s*=\s*[\[{]\s*\.\.\.\s*\1\b")
_JS_SELF_CONCAT = re.compile(r"\b([A-Za-z_$][\w$]*)\s*=\s*\1\s*\.\s*concat\s*\(")
_JS_SHIFT = re.compile(r"\.\s*(shift|unshift)\s*\(|\.\s*splice\s*\(\s*0\b")
_JS_COPY = re.compile(r"JSON\s*\.\s*parse\s*\(\s*JSON\s*\.\s*stringify|structuredClone\s*\(")
_JS_REGEXNEW = re.compile(r"\bnew\s+RegExp\s*\(")
_JS_IO = re.compile(r"\b(?:await\s+)?(?:fetch|axios\s*\.\s*\w+|https?\s*\.\s*request)\s*\(|"
                    r"\.\s*(?:query|execute|findOne|findFirst|findMany|findUnique|insertOne|updateOne|"
                    r"deleteOne|aggregate|save|exec)\s*\(|\bprisma\s*\.|\bknex\s*\(|\bdb\s*\.\s*\w+\s*\(")
_JS_AWAIT = re.compile(r"\bawait\b")


def js_reduce_acc(masked, L):
    """Name of a `.reduce(` callback's accumulator — re-spreading THAT is the
    quadratic pattern (`reduce((acc, x) => [...acc, x], [])` rebuilds the whole
    array on every element)."""
    if L.method not in ("reduce", "reduceRight"):
        return None
    i, n = L.body, len(masked)
    while i < n and masked[i].isspace():
        i += 1
    if masked.startswith("function", i):
        i = masked.find("(", i)
    if i < 0 or i >= n or masked[i] != "(":
        return None
    first = masked[i + 1:match_paren(masked, i) - 1].split(",")[0].strip()
    m = re.match(r"[A-Za-z_$][\w$]*", first)
    return m.group(0) if m else None


def js_body_ops(masked, L, inner_spans):
    """Costly operations in THIS loop's body, excluding nested-loop bodies (those
    are priced by their own level — counting them twice would inflate the exponent)."""
    seg = _mask_out(masked, L.body, L.end, inner_spans)
    pats = [(_JS_SCAN, "scan"), (_JS_OBJ_SCAN, "scan"), (_JS_SORT, "sort"),
            (_JS_SELF_SPREAD, "concat"), (_JS_SELF_CONCAT, "concat"),
            (_JS_SHIFT, "shift"), (_JS_COPY, "copy"),
            (_JS_REGEXNEW, "regex"), (_JS_IO, "io")]
    acc = js_reduce_acc(masked, L)
    if acc:
        pats.append((re.compile(r"[\[{]\s*\.\.\.\s*%s\b" % re.escape(acc)), "concat"))
        pats.append((re.compile(r"\b%s\s*\.\s*concat\s*\(" % re.escape(acc)), "concat"))
    ops = []
    for rx, kind in pats:
        for m in rx.finditer(seg):
            ops.append((kind, L.body + m.start(), m.group(0).strip()))
    if not any(k == "io" for k, _, _ in ops):
        for m in _JS_AWAIT.finditer(seg):
            ops.append(("await", L.body + m.start(), "await"))
            break
    return ops


def _mask_out(masked, a, b, spans):
    """masked[a:b] with `spans` blanked — keeps offsets aligned to the slice."""
    seg = list(masked[a:b])
    for s, e in spans:
        for k in range(max(s, a) - a, min(e, b) - a):
            if 0 <= k < len(seg) and seg[k] != "\n":
                seg[k] = " "
    return "".join(seg)


_JS_FN = re.compile(
    r"(?:\bfunction\s*\*?\s*(?P<f1>[A-Za-z_$][\w$]*)?\s*\()"
    r"|(?:\b(?:const|let|var)\s+(?P<f2>[A-Za-z_$][\w$]*)\s*(?::[^=;]+)?=\s*(?:async\s+)?(?:function\b|\())"
    r"|(?:^[ \t]*(?:(?:public|private|protected|static|async|export|default)\s+)*(?P<f3>[A-Za-z_$][\w$]*)\s*\([^;{}()]*\)\s*(?::[^{;=]+)?\{)",
    re.M)


def js_body_brace(masked, params_end):
    """Offset of the `{` that opens the function BODY, or -1.

    The hard case is TypeScript: `function f(): { a: X } { ... }` puts a braced
    RETURN TYPE between the parameters and the body, and `Promise<{a: X}>` puts one
    inside angle brackets. Taking the first `{` after the parameters — which is the
    obvious implementation — analyses the return type as if it were the function,
    so every loop in the real body lands outside every known function and gets
    attributed to "(top level)". Depths are tracked so type braces are skipped.
    """
    n = len(masked)
    i = params_end
    while i < n and masked[i].isspace():
        i += 1
    if i >= n:
        return -1
    if masked[i] == "{":
        return i
    if masked.startswith("=>", i):
        j = i + 2
        while j < n and masked[j].isspace():
            j += 1
        return j if j < n and masked[j] == "{" else -1
    if masked[i] != ":":
        return -1
    depth, j = 0, i + 1
    while j < n:
        c = masked[j]
        if c in "<([":
            depth += 1
        elif c in ">)]":
            depth -= 1
        elif c in ";=":
            return -1
        elif c == "{":
            if depth > 0:                      # brace inside `Promise<{…}>`
                j = match_brace(masked, j)
                continue
            close = match_brace(masked, j)
            k = close
            while k < n and masked[k].isspace():
                k += 1
            return k if k < n and masked[k] == "{" else j
        j += 1
    return -1


def js_functions(masked, starts):
    """(name, start, body_open, end, line) for each function-ish block."""
    out = []
    for m in _JS_FN.finditer(masked):
        name = m.group("f1") or m.group("f2") or m.group("f3") or "(anonymous)"
        if name in _JS_KEYWORDS:
            continue
        p = masked.find("(", m.start())
        if p < 0:
            continue
        b = js_body_brace(masked, match_paren(masked, p))
        if b < 0:
            continue
        out.append((name, m.start(), b, match_brace(masked, b), off_to_line(starts, m.start())))
    out.sort(key=lambda t: (t[1], -t[3]))
    return out


# ─────────────────────────────────────────────────────────── JS: bigo pass ───


_JS_CALL = re.compile(r"(?<![\w$.])([A-Za-z_$][\w$]*)\s*\(")
_JS_GLOBALS = {"require", "import", "String", "Number", "Boolean", "Array", "Object",
               "Map", "Set", "Date", "Error", "Promise", "JSON", "Math", "RegExp",
               "parseInt", "parseFloat", "isNaN", "Symbol", "BigInt", "WeakMap",
               "setTimeout", "setInterval", "clearTimeout", "fetch", "structuredClone",
               "expect", "describe", "it", "test", "beforeEach", "afterEach"}


def js_bigo(path, src, masked, starts):
    """→ (op_findings, [FnInfo]). The per-op findings (N+1, sort-in-loop…) stand on
    their own; the per-function costs go through propagate() first."""
    findings = []
    loops = js_loops(masked, starts)
    fns = js_functions(masked, starts)
    consts = js_const_arrays(src)

    def enclosing_fn(off):
        best = None
        for t in fns:
            if t[2] <= off < t[3] and (best is None or t[2] > best[2]):
                best = t
        return best

    # nest loops by containment
    roots, stack = [], []
    for L in loops:
        while stack and not (stack[-1].body <= L.start < stack[-1].end):
            stack.pop()
        (stack[-1].children if stack else roots).append(L)
        stack.append(L)

    L_ev, L_total = {}, {}

    def price(L):
        size, why = js_loop_size(masked, L, consts)
        inner = [(c.start, c.end) for c in L.children]
        ops = js_body_ops(masked, L, inner)
        here, ev = CONST, []
        for kind, off, txt in ops:
            oc, sev, msg, fix = OPS[kind]
            ln = off_to_line(starts, off)
            here = cx_max(here, oc)
            if kind in ("io", "await", "regex", "copy") or cx_str(oc) != "O(1)":
                ev.append((kind, ln, txt, sev, msg, fix))
        # Remember WHICH child produced the cost. Sibling loops are additive (the max
        # wins), not multiplicative — rendering them all joined by "×" claimed a
        # derivation the verdict does not have, and an evidence chain you cannot audit
        # is worse than none.
        sub, best_child = CONST, None
        for c in L.children:
            cc = price(c)
            if cx_max(sub, cc) != sub:
                sub, best_child = cc, c
        total = cx_mul(size, cx_max(here, sub))
        L_ev[L] = (size, why, ev, best_child)
        L_total[L] = total
        return total

    for r in roots:
        price(r)

    # every loop body span with its own size, for call-site factors
    flat = [(L.body, L.end, L_ev[L][0]) for r in roots for L in _walk(r)]

    def factor_at(off, host_body=0):
        """Product of the loops enclosing `off` — but only those that start inside
        the function the call is attributed to. Without that bound, a method defined
        inside a factory inherited loop factors from its enclosing scope and reported
        `O(n²)` while its own evidence line said the callee was `O(1)`. It also caps
        the blast radius of any brace-matching error to one function."""
        f = CONST
        for a, b, sz in flat:
            if a <= off < b and a >= host_body:
                f = cx_mul(f, sz)
        return f

    infos = {}

    def info_for(off):
        fn = enclosing_fn(off)
        key = (path, fn[2] if fn else -1)
        if key not in infos:
            infos[key] = FnInfo(path, key, fn[0] if fn else "(top level)",
                                fn[4] if fn else 1)
        return infos[key]

    for r in roots:
        info = info_for(r.start)
        total = L_total[r]
        if cx_max(info.self_cost, total) != info.self_cost:
            info.self_cost = info.total = total
            info.worst_line = r.line
            info.chain, fx = _chain_evidence(r, L_ev, starts, masked)
            info.fix = fx
        for L in _walk(r):
            for kind, ln, txt, sev, msg, fix in L_ev[L][2]:
                if kind in ("io", "await", "shift", "concat", "sort", "copy", "regex"):
                    findings.append(F(path, ln, "bigo", sev,
                                      "%s: `%s` inside the loop at line %d" % (msg, txt, L.line), fix))

    # Call sites → the interprocedural edges. Deliberately NOT filtered to names
    # defined in THIS file: that filter silently dropped every cross-file call, which
    # is most of them in a real codebase. propagate() resolves a name only when it is
    # defined exactly once across the whole run, so unresolvable names cost nothing.
    for m in _JS_CALL.finditer(masked):
        name = m.group(1)
        if name in _JS_KEYWORDS or name in _JS_GLOBALS:
            continue
        off = m.start()
        # A definition's own header (`function findUser(`) looks exactly like a call
        # site. Checking only the ENCLOSING function misses every top-level
        # definition, whose name sits outside any function body — which made each
        # one read as "(top level) calls X".
        if any(t[1] <= off < t[2] for t in fns):
            continue
        info = info_for(off)
        # Module-scope code calling an expensive function is not a finding; it is
        # just calling it. Only real top-level LOOPS are attributed there.
        if info.name in ("(top level)", name):
            continue
        host = enclosing_fn(off)
        fac = factor_at(off, host[2] if host else 0)
        if fac == CONST:
            continue                      # not in a loop ⇒ no new cost to report
        info.calls.append((name, fac, off_to_line(starts, off)))

    return findings, list(infos.values())


def _walk(L):
    yield L
    for c in L.children:
        yield from _walk(c)


# A write into a two-dimensional cell is the signature of a DP table or a pairwise
# matrix (edit distance, LCS, similarity grids). For those, O(n·m) is the LOWER BOUND
# of the shape, not a defect — and "pre-index the inner collection" is nonsense advice
# that teaches the reader the tool does not understand their code.
_MATRIX_FILL = re.compile(r"\w[\w$.]*\s*\[[^\]\n]+\]\s*\[[^\]\n]+\]\s*(?:[-+*/|&]?=[^=])")
INHERENT_FIX = ("this looks like a 2-D table/matrix fill, where O(n·m) IS the lower bound — "
                "if that is what it is, say so and move on; only a different algorithm "
                "(not an index or a cache) can beat it")


def _chain_evidence(root, L_ev, starts, masked):
    """The derivation that actually produced the exponent: root → the child that won,
    not every loop in the subtree."""
    parts, fix, L = [], "", root
    innermost = root
    while L is not None:
        size, why, ev, best = L_ev[L]
        parts.append("loop@%d over `%s` (%s)" % (L.line, L.subject, cx_str(size)))
        for kind, ln, txt, sev, msg, f in ev:
            if kind == "scan":
                parts.append("`%s` scan@%d (O(n))" % (txt, ln))
                fix = fix or f
            elif kind in ("sort", "concat", "shift"):
                parts.append("%s@%d" % (kind, ln))
                fix = fix or f
        innermost, L = L, best
    if not fix and _MATRIX_FILL.search(masked[innermost.body:innermost.end]):
        fix = INHERENT_FIX
    return " × ".join(parts), fix


# ────────────────────────────────────────────────────────── JS: bounds pass ───

# Operands must not swallow a trailing `)` — `n > LIMIT)` and `n >= LIMIT` would
# otherwise hash to different pairs and the differential check would miss them.
_CMP = re.compile(r"([A-Za-z_$][\w$.\[\]]*|\d+)\s*(<=|>=|<|>|===|!==|==|!=)\s*([A-Za-z_$][\w$.\[\]]*|\d+)")


def brace_body_after(masked, pos):
    """The `{...}` block that IMMEDIATELY follows pos, or "" if the next thing is
    not a brace. Searching forward for the next `{` instead would silently pick up
    an unrelated block further down the file — which is exactly how a `do {...}
    while (c)` tail got analysed against the next type declaration."""
    i, n = pos, len(masked)
    while i < n and masked[i].isspace():
        i += 1
    if i >= n or masked[i] != "{":
        return ""
    return masked[i:match_brace(masked, i)]


def split_top(s, sep):
    """Split on `sep` at bracket depth 0 only."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def js_bounds(path, src, masked, starts):
    fs = []
    L = lambda o: off_to_line(starts, o)

    # The header is taken by paren MATCHING, not by a `([^;]*);([^;]*);([^)]*)`
    # regex — that pattern happily runs past the closing paren and splices the
    # loop BODY's semicolons into `cond`/`step`, which turns every `for…of` into a
    # bogus C-style loop with an invented direction bug.
    for m in re.finditer(r"\bfor\s*(?:await\s*)?\(", masked):
        pe = match_paren(masked, m.end() - 1)
        parts = split_top(masked[m.end():pe - 1], ";")
        if len(parts) != 3:
            continue                                  # for…of / for…in: no C-style bounds
        init, cond, step = parts
        ln = L(m.start())
        var = None
        vm = re.search(r"\b([A-Za-z_$][\w$]*)\s*=", init)
        if vm:
            var = vm.group(1)
        # RHS may be a numeric literal (`i >= 0`) — omitting digits here silently
        # skipped every countdown loop, which is where the step/direction bugs live.
        cm = re.search(r"([A-Za-z_$][\w$]*)\s*(<=|>=|<|>)\s*([A-Za-z_$][\w$.]*|\d+)", cond)
        # `.length` must END the condition: `i <= line.length - keyLen` is the
        # correct bound for a sliding window of size keyLen, and matching a bare
        # prefix would call it an off-by-one. (An off-by-one in the off-by-one
        # detector — found by auditing its output against real code.)
        if cm and cm.group(2) == "<=" and cm.group(3).endswith(".length") \
                and cond.strip().endswith(cm.group(3)):
            arr = cm.group(3)[:-len(".length")]
            body = brace_body_after(masked, pe)
            # A run-boundary sweep deliberately steps onto the sentinel and handles
            # it — either by comparing the index to the length, or by testing the
            # read value for undefined/null. Both shapes are correct code.
            guarded = re.search(r"\b%s\s*(?:===?|<)\s*%s\s*\.\s*length"
                                % (re.escape(cm.group(1)), re.escape(arr)), body) or \
                re.search(r"[!=]==?\s*(?:undefined|null)\b|\?\?", body)
            if not guarded:
                fs.append(F(path, ln, "bounds", "certain",
                            "loop runs one past the end: `%s <= %s` — the last index is %s - 1"
                            % (cm.group(1), cm.group(3), cm.group(3)),
                            "use `<` (`%s < %s`)" % (cm.group(1), cm.group(3))))
        # Direction is only decidable for a SINGLE comparison with a LITERAL step.
        # `for (let i = from; i >= 0 && i < n; i += dir)` is a legitimate
        # bidirectional scan: the delta is a variable, so no direction is implied.
        simple = "&&" not in cond and "||" not in cond
        up = bool(re.search(r"\+\+", step)) or bool(re.search(r"\+=\s*\d+\s*$", step.strip()))
        down = bool(re.search(r"--", step)) or bool(re.search(r"-=\s*\d+\s*$", step.strip()))
        if var and cm and cm.group(1) == var and simple and (up != down):
            if cm.group(2) in ("<", "<=") and down:
                fs.append(F(path, ln, "bounds", "certain",
                            "loop never terminates: condition `%s %s ...` counts UP but the step counts DOWN"
                            % (var, cm.group(2)), "flip the step to `%s++` or the condition to `>=`" % var))
            if cm.group(2) in (">", ">=") and up:
                fs.append(F(path, ln, "bounds", "certain",
                            "loop never terminates: condition `%s %s ...` counts DOWN but the step counts UP"
                            % (var, cm.group(2)), "flip the step to `%s--` or the condition to `<`" % var))
        # index+1 inside a `< length` loop reads past the end on the last pass
        if var and cm and cm.group(2) == "<" and cm.group(3).endswith(".length"):
            arr = cm.group(3)[:-len(".length")]
            b = pe
            body = brace_body_after(masked, b)
            if body:
                if re.search(r"%s\s*\[\s*%s\s*\+\s*1\s*\]" % (re.escape(arr), re.escape(var)), body):
                    fs.append(F(path, ln, "bounds", "high",
                                "reads `%s[%s + 1]` while looping to `%s.length` — the final iteration is undefined"
                                % (arr, var, arr),
                                "stop at `%s.length - 1`, or guard the pair access" % arr))
                for om in re.finditer(r"\b([A-Za-z_$][\w$]*)\s*\[\s*%s\s*\]" % re.escape(var), body):
                    other = om.group(1)
                    if other != arr and other not in ("this", "self"):
                        fs.append(F(path, L(b + om.start()), "bounds", "high",
                                    "indexes `%s[%s]` but the loop is bounded by `%s.length` — "
                                    "if `%s` is shorter this reads undefined"
                                    % (other, var, arr, other),
                                    "bound by `Math.min(%s.length, %s.length)` or assert equal lengths" % (arr, other)))
                        break

    for m in re.finditer(r"\bwhile\s*\(([^)]*)\)", masked):
        cond, ln = m.group(1), L(m.start())
        # Root identifiers only: `(?<![\w$.])` keeps `x7f` out of `0x7f` and reduces
        # `L.i` to `L`, which is the thing a mutation would actually happen to.
        names = set(re.findall(r"(?<![\w$.])[A-Za-z_$][\w$]*", cond)) - \
            {"true", "false", "null", "undefined", "length"}
        body = brace_body_after(masked, m.end())
        if not body or not names:
            continue                      # do-while tail or braceless body: not provable
        # A CALL in the condition can advance state by itself (`while (re.exec(s) !== null)`
        # walks lastIndex), so nothing about termination is provable — stay silent.
        # Likewise a method call on a condition name (`queue.shift()`) or an await.
        # Claiming "infinite loop" wrongly is far worse than missing one, so every
        # one of these buys silence.
        def advanced(nm):
            e = re.escape(nm)
            return (re.search(r"\b%s\s*(=[^=]|\+\+|--|[-+*/%%&|^]=|>>>?=|<<=)" % e, body)
                    or re.search(r"(\+\+|--)\s*%s\b" % e, body)
                    # a whole property CHAIN, not one step: `state.errorHistory.shift()`
                    or re.search(r"\b%s(?:\s*(?:\.\s*\w+|\[[^\]]*\]))+\s*(?:\(|\+\+|--|=[^=])" % e, body)
                    # handed to a callee that can mutate it (`advance(L)`) — measured
                    # on 125k lines of real TS, every "no update" hit was this shape
                    or re.search(r"[(,]\s*%s\s*[),]" % e, body))
        if "(" not in cond and not any(advanced(nm) for nm in names) \
                and not re.search(r"\b(break|return|throw|yield|await)\b", body):
            fs.append(F(path, ln, "bounds", "certain",
                        "`while (%s)` never updates %s in its body and has no break — infinite loop"
                        % (cond.strip(), " / ".join(sorted(names))),
                        "advance the condition variable, or add the exit you meant"))
        # classic binary-search off-by-one
        if re.search(r"\b(lo|low|left|l|start)\b\s*<=\s*\b(hi|high|right|r|end)\b", cond) and \
           re.search(r"\b(hi|high|right|r|end)\s*=\s*mid\s*[;\n]", body):
            fs.append(F(path, ln, "bounds", "certain",
                        "binary search with `<=` bound but `hi = mid` (not `mid - 1`) — loops forever when hi == lo + 1",
                        "either `while (lo < hi)` with `hi = mid`, or `while (lo <= hi)` with `hi = mid - 1`"))

    for m in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*\(([^()]*\+[^()]*)\)\s*/\s*2\b", masked):
        nm = m.group(1)
        if re.search(r"\[\s*%s\s*\]" % re.escape(nm), masked):
            fs.append(F(path, L(m.start()), "bounds", "certain",
                        "`%s = (%s) / 2` is used as an index but JS division yields a float"
                        % (nm, m.group(2).strip()),
                        "wrap it: `Math.floor((%s) / 2)` or use `>> 1`" % m.group(2).strip()))

    for m in re.finditer(r"\.\s*(indexOf|findIndex|search)\s*\(([^()]*)\)\s*(>|>=)\s*(-?\d+)", masked):
        op, num = m.group(3), int(m.group(4))
        if (op == ">" and num == 0) or (op == ">=" and num == 1):
            # `high`, not `certain`: this is correct when index 0 is genuinely
            # special (a root node at the head of a list), so it is a question to
            # answer, not a proven defect.
            fs.append(F(path, L(m.start()), "bounds", "high",
                        "`%s(...) %s %d` treats a match at index 0 as no match"
                        % (m.group(1), op, num),
                        "if index 0 is not special, compare against -1: `%s(...) !== -1`" % m.group(1)))

    for m in re.finditer(r"\bif\s*\(\s*([A-Za-z_$][\w$.]*)\s*=\s*([^=][^)]*)\)", masked):
        fs.append(F(path, L(m.start()), "bounds", "certain",
                    "assignment inside a condition: `if (%s = %s)` assigns, it does not compare"
                    % (m.group(1), m.group(2).strip()[:30]),
                    "use `===` (or wrap in an extra paren if the assignment is deliberate)"))

    for m in re.finditer(r"\.length\s*(>=\s*0|<\s*0)\b", masked):
        fs.append(F(path, L(m.start()), "bounds", "certain",
                    "`.length %s` is constant — length is never negative" % m.group(1).strip(),
                    "you almost certainly meant `> 0` (non-empty) or `=== 0` (empty)"))

    for m in re.finditer(r"\bfor\s*\(\s*(?:const|let|var)\s+\w+\s+in\s+([A-Za-z_$][\w$.]*)\s*\)", masked):
        nm = m.group(1)
        if re.search(r"\b%s\s*=\s*\[|\b%s\s*:\s*\w+\[\]" % (re.escape(nm), re.escape(nm)), masked) or \
           re.search(r"\b%s\s*\.\s*(push|length)\b" % re.escape(nm), masked):
            fs.append(F(path, L(m.start()), "bounds", "high",
                        "`for...in` over the array `%s` yields STRING keys and inherited properties" % nm,
                        "use `for (const x of %s)` or `%s.forEach`" % (nm, nm)))

    for m in re.finditer(r"catch\s*\([^)]*\)\s*\{\s*\}", masked):
        fs.append(F(path, L(m.start()), "bounds", "high",
                    "empty catch swallows the failure — the caller cannot tell success from silence",
                    "log with context and rethrow, or return an explicit error value"))

    fs += cmp_inconsistency(path, masked, starts)
    return fs


# The flagship differential check for problem 1 — a dropped `=` is invisible on
# one line and obvious across two. Direction is canonicalised so `a > b` and
# `b < a` land in the same bucket.
_FLIP = {"<": ">", ">": "<", "<=": ">=", ">=": "<="}


def _canon(l, op, r):
    if op in ("<", "<=") or (op in (">", ">=") and l <= r):
        if op in (">", ">="):
            l, r, op = r, l, _FLIP[op]
        return (l, r, op)
    return (r, l, _FLIP[op])


def cmp_inconsistency(path, masked, starts, py_cmps=None):
    """Both callers hand in LINE numbers — the JS side converts its offsets here,
    so nothing downstream has to know which front end it came from."""
    seen = {}
    src = py_cmps if py_cmps is not None else [
        (m.group(1), m.group(2), m.group(3), off_to_line(starts, m.start()))
        for m in _CMP.finditer(masked) if m.group(2) in ("<", ">", "<=", ">=")]
    for l, op, r, ln in src:
        if l == r or (l.isdigit() and r.isdigit()):
            continue
        key = _canon(l.strip(), op, r.strip())
        seen.setdefault((key[0], key[1]), []).append((key[2], ln))
    out = []
    for (l, r), uses in seen.items():
        ops = {o for o, _ in uses}
        if len(ops) > 1 and {o.rstrip("=") for o in ops} == {list(ops)[0].rstrip("=")}:
            lines = sorted({ln for _, ln in uses})
            if len(lines) < 2:
                continue
            out.append(F(path, lines[0], "bounds", "high",
                         "boundary inconsistency: `%s` vs `%s` compare the same pair (`%s` / `%s`) at lines %s "
                         "— one of them is missing or has a stray `=`"
                         % (min(ops), max(ops), l, r, ", ".join(map(str, lines))),
                         "decide whether the boundary value is IN or OUT, then use the same operator at every site"))
    return out


# ─────────────────────────────────────────────────────────── JS: fluff pass ───

_STOP = {"the", "a", "an", "of", "to", "for", "and", "we", "this", "that", "is",
         "it", "in", "on", "by", "then", "with", "if", "so", "our", "its", "as"}


def _words(s):
    return {w.lower() for w in re.findall(r"[A-Za-z][A-Za-z0-9]*", s)} - _STOP


def _split_ident(s):
    return {w.lower() for w in re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])", s)} - _STOP


def comment_fluff(path, src, comments):
    """A comment whose words are a subset of the very next line's identifiers is
    restating the code. That is pure volume: it ages badly and says nothing."""
    lines = src.splitlines()
    out = []
    for ln, text in comments:
        w = _words(text)
        if len(w) < 2:
            continue
        nxt = ""
        for k in range(ln, min(ln + 3, len(lines))):
            if lines[k].strip() and not lines[k].strip().startswith(("//", "#", "*", "/*")):
                nxt = lines[k]
                break
        if not nxt:
            continue
        code_words = set()
        for ident in re.findall(r"[A-Za-z_$][\w$]*", nxt):
            code_words |= _split_ident(ident)
        if w and w <= code_words:
            out.append(F(path, ln, "fluff", "medium",
                         "comment restates the next line (`%s`)" % text.strip()[:60],
                         "delete it — say WHY if there is a why, otherwise nothing", 1))
    return out


def js_fluff(path, src, masked, starts, comments):
    fs = []
    L = lambda o: off_to_line(starts, o)

    for m in re.finditer(r"\bif\s*\(([^)]*)\)\s*\{?\s*return\s+(true|false)\s*;?\s*\}?\s*"
                         r"(?:else\s*\{?\s*)?return\s+(true|false)\s*;?", masked):
        if m.group(2) != m.group(3):
            neg = "" if m.group(2) == "true" else "!"
            # Quote the ORIGINAL text, not the mask — masked string literals are
            # blanked, so a hint built from `masked` suggests `x === '        '`.
            cond = src[m.start(1):m.end(1)].strip()
            fs.append(F(path, L(m.start()), "fluff", "medium",
                        "if/return true/false is just the condition",
                        "`return %s(%s);`" % (neg, cond), 3))

    for m in re.finditer(r"\bcatch\s*\(\s*([A-Za-z_$][\w$]*)\s*\)\s*\{\s*throw\s+\1\s*;?\s*\}", masked):
        fs.append(F(path, L(m.start()), "fluff", "medium",
                    "try/catch that rethrows unchanged does nothing",
                    "delete the try/catch — the exception already propagates", 3))

    for m in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]{1,80});\s*\n\s*return\s+\1\s*;", masked):
        fs.append(F(path, L(m.start()), "fluff", "low",
                    "`%s` is assigned then immediately returned" % m.group(1),
                    "`return %s;`" % m.group(2).strip(), 1))

    for name, s, b, e, ln in js_functions(masked, starts):
        body = masked[b:e]
        for dm in re.finditer(r"\b(?:const|let)\s+([A-Za-z_$][\w$]*)\s*(?::[^=;]+)?=", body):
            nm = dm.group(1)
            if len(re.findall(r"\b%s\b" % re.escape(nm), body)) == 1 and not nm.startswith("_"):
                fs.append(F(path, L(b + dm.start()), "fluff", "medium",
                            "`%s` is declared in %s and never used" % (nm, name),
                            "delete the declaration and whatever only feeds it", 1))
        depth, maxd = 0, 0
        for ch in body:
            if ch == "{":
                depth += 1
                maxd = max(maxd, depth)
            elif ch == "}":
                depth -= 1
        if maxd >= 5:
            fs.append(F(path, ln, "fluff", "medium",
                        "`%s` nests %d levels deep" % (name, maxd),
                        "invert the conditions into guard clauses and return early", 0))

    fs += comment_fluff(path, src, comments)
    for m in re.finditer(r"\bconsole\s*\.\s*(log|debug)\s*\(", masked):
        fs.append(F(path, L(m.start()), "fluff", "low",
                    "leftover `console.%s`" % m.group(1),
                    "delete it, or route it through the real logger", 1))
    return fs


# ─────────────────────────────────────────────────────── Python front + passes ───

_COMPS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
_LOOPS = (ast.For, ast.AsyncFor, ast.While) + _COMPS
_PY_IO = re.compile(r"^(execute|executemany|query|fetchone|fetchall|fetchmany|get|post|put|delete|"
                    r"request|urlopen|find_one|find|insert_one|update_one|save|commit|read|write|"
                    r"connect|call|invoke)$")
_PY_IO_RECV = re.compile(r"(cursor|conn|connection|db|session|client|requests|httpx|urllib|s3|redis|"
                         r"collection|engine|api|http)", re.I)


def py_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return py_name(node.value) + "." + node.attr
    if isinstance(node, ast.Call):
        return py_name(node.func) + "()"
    if isinstance(node, ast.Subscript):
        return py_name(node.value) + "[]"
    if isinstance(node, ast.Constant):
        return repr(node.value)
    return "?"


class PyCtx:
    """Names we have positive evidence are list-like (linear `in`) — assigned a
    list literal / list() / .split(), or grown with append/insert/extend. A set or
    dict membership test is O(1) and must never be flagged."""

    def __init__(self, tree):
        self.listy = set()
        self.stringy = set()
        self.const = set()          # bound to a literal collection ⇒ fixed size, O(1)
        for n in ast.walk(tree):
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                v, nm = n.value, n.targets[0].id
                if isinstance(v, (ast.List, ast.Tuple, ast.Set)) and v.elts and len(v.elts) <= 40 \
                        and all(isinstance(e, ast.Constant) for e in v.elts):
                    self.const.add(nm)
                if isinstance(v, (ast.List, ast.ListComp)):
                    self.listy.add(nm)
                elif isinstance(v, ast.Call) and isinstance(v.func, ast.Name) and v.func.id in ("list", "sorted"):
                    self.listy.add(nm)
                elif isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and v.func.attr in ("split", "readlines", "splitlines"):
                    self.listy.add(nm)
                elif isinstance(v, ast.Constant) and isinstance(v.value, str):
                    self.stringy.add(nm)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and \
                    n.func.attr in ("append", "insert", "extend") and isinstance(n.func.value, ast.Name):
                self.listy.add(n.func.value.id)
            if isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
                ann = py_name(n.annotation)
                if ann.split("[")[0].lower() in ("list", "typing.list", "sequence"):
                    self.listy.add(n.target.id)


def _iter_size(it, ctx=None):
    if ctx is not None and isinstance(it, ast.Name) and it.id in ctx.const:
        return CONST, "iterates a fixed literal collection"
    if isinstance(it, ast.Call) and isinstance(it.func, ast.Name) and it.func.id == "range":
        if it.args and all(isinstance(a, ast.Constant) for a in it.args):
            return CONST, "fixed numeric range"
        return LIN, "range over a data-dependent bound"
    if isinstance(it, (ast.List, ast.Tuple)) and all(isinstance(e, ast.Constant) for e in it.elts):
        return CONST, "iterates a literal"
    return LIN, "iterates a data-dependent collection"


def py_loop_size(node, ctx):
    # A comprehension IS a loop, and one with several `for` clauses is several
    # nested loops — `[f(x) for a in A for b in B]` is O(n·m). Python backend code
    # is written in comprehensions, so skipping them would blind the checker to
    # most of the N+1s and quadratic scans it exists to find.
    if isinstance(node, _COMPS):
        total = CONST
        for g in node.generators:
            total = cx_mul(total, _iter_size(g.iter, ctx)[0])
        return total, "comprehension over %d generator(s)" % len(node.generators)
    if isinstance(node, (ast.For, ast.AsyncFor)):
        return _iter_size(node.iter, ctx)
    # while: halving or doubling ⇒ log
    names = {n.id for n in ast.walk(node.test) if isinstance(n, ast.Name)}
    for s in ast.walk(node):
        tgt = None
        if isinstance(s, ast.AugAssign) and isinstance(s.target, ast.Name):
            tgt, val, op = s.target.id, s.value, s.op
            if tgt in names and isinstance(op, (ast.FloorDiv, ast.Div, ast.Mult, ast.RShift, ast.LShift)) \
                    and isinstance(val, ast.Constant) and val.value == 2:
                return LOGN, "the loop variable halves/doubles each step"
        if isinstance(s, ast.Assign) and len(s.targets) == 1 and isinstance(s.targets[0], ast.Name):
            nm, v = s.targets[0].id, s.value
            if nm in names and isinstance(v, ast.BinOp) and isinstance(v.op, (ast.FloorDiv, ast.Div, ast.Mult)) \
                    and isinstance(v.right, ast.Constant) and v.right.value == 2:
                return LOGN, "the loop variable halves/doubles each step"
            if nm in names and isinstance(v, ast.BinOp) and isinstance(v.left, ast.Name) and v.left.id == "mid":
                return LOGN, "binary-search bound update"
    return LIN, "while over a data-dependent condition"


def py_body_ops(node, ctx, inner):
    """Costly ops directly in this loop's body (children excluded)."""
    skip = set()
    for c in inner:
        for s in ast.walk(c):
            skip.add(id(s))
    if isinstance(node, _COMPS):
        # The things being iterated are not work done per iteration.
        for g in node.generators:
            for s in ast.walk(g.iter):
                skip.add(id(s))
    ops = []
    for s in ast.walk(node):
        if id(s) in skip or s is node:
            continue
        if isinstance(s, ast.Compare) and any(isinstance(o, (ast.In, ast.NotIn)) for o in s.ops):
            cmpr = s.comparators[0]
            nm = py_name(cmpr)
            if (isinstance(cmpr, ast.Name) and cmpr.id in ctx.listy) or isinstance(cmpr, (ast.List, ast.ListComp)):
                ops.append(("scan", s.lineno, "%s in %s" % (py_name(s.left), nm)))
        if isinstance(s, ast.Call):
            fn = s.func
            if isinstance(fn, ast.Attribute):
                a = fn.attr
                recv = py_name(fn.value)
                if a in ("index", "count", "remove") and isinstance(fn.value, ast.Name) and fn.value.id in ctx.listy:
                    ops.append(("scan", s.lineno, "%s.%s()" % (recv, a)))
                elif a == "sort":
                    ops.append(("sort", s.lineno, "%s.sort()" % recv))
                elif a == "pop" and s.args and isinstance(s.args[0], ast.Constant) and s.args[0].value == 0:
                    ops.append(("shift", s.lineno, "%s.pop(0)" % recv))
                elif a == "insert" and s.args and isinstance(s.args[0], ast.Constant) and s.args[0].value == 0:
                    ops.append(("shift", s.lineno, "%s.insert(0, ...)" % recv))
                elif a in ("deepcopy", "copy"):
                    ops.append(("copy", s.lineno, "%s.%s()" % (recv, a)))
                elif a == "compile" and recv.endswith("re"):
                    ops.append(("regex", s.lineno, "re.compile()"))
                elif _PY_IO.match(a) and _PY_IO_RECV.search(recv):
                    ops.append(("io", s.lineno, "%s.%s()" % (recv, a)))
            elif isinstance(fn, ast.Name):
                if fn.id == "sorted":
                    ops.append(("sort", s.lineno, "sorted()"))
                elif fn.id in ("deepcopy",):
                    ops.append(("copy", s.lineno, "deepcopy()"))
        if isinstance(s, ast.AugAssign) and isinstance(s.op, ast.Add) and isinstance(s.target, ast.Name) \
                and s.target.id in ctx.stringy:
            ops.append(("concat", s.lineno, "%s += ..." % s.target.id))
        if isinstance(s, ast.Await) and not any(k == "io" for k, _, _ in ops):
            ops.append(("await", s.lineno, "await"))
    return ops


def py_child_loops(node):
    """Loops nested directly inside `node` (not deeper). Comprehensions count."""
    out = []

    def rec(n):
        for ch in ast.iter_child_nodes(n):
            if isinstance(ch, _LOOPS):
                out.append(ch)
            elif isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue
            else:
                rec(ch)

    if isinstance(node, _COMPS):
        # A comprehension has no `.body` — its per-iteration work is the element
        # expression plus the filter clauses.
        parts = ([node.key, node.value] if isinstance(node, ast.DictComp) else [node.elt])
        parts += [i for g in node.generators for i in g.ifs]
    else:
        parts = list(node.body) + list(getattr(node, "orelse", []))
    for p in parts:
        if isinstance(p, _LOOPS):
            out.append(p)
        else:
            rec(p)
    return out


def py_bigo(path, tree, ctx):
    fs = []
    ev_store = {}

    def price(node):
        size, why = py_loop_size(node, ctx)
        kids = py_child_loops(node)
        ops = py_body_ops(node, ctx, kids)
        here, ev = CONST, []
        for kind, ln, txt in ops:
            oc, sev, msg, fix = OPS[kind]
            here = cx_max(here, oc)
            ev.append((kind, ln, txt, sev, msg, fix))
        sub, best = CONST, None          # which child actually produced the cost
        for k in kids:
            kc = price(k)
            if cx_max(sub, kc) != sub:
                sub, best = kc, k
        ev_store[id(node)] = (node, size, why, ev, kids, best)
        return cx_mul(size, cx_max(here, sub))

    def subject(node):
        if isinstance(node, _COMPS):
            return py_name(node.generators[0].iter)
        return py_name(node.iter) if isinstance(node, (ast.For, ast.AsyncFor)) else "condition"

    def chain(node):
        """Only the winning path — siblings are additive, so joining them with `×`
        would assert a derivation the verdict does not have."""
        parts, fix, nd = [], "", node
        innermost = node
        while nd is not None:
            _n, size, _why, ev, _kids, best = ev_store[id(nd)]
            parts.append("loop@%d over `%s` (%s)" % (nd.lineno, subject(nd), cx_str(size)))
            for kind, ln, txt, sev, msg, f in ev:
                if kind in ("scan", "sort", "concat", "shift"):
                    parts.append("`%s`@%d" % (txt, ln))
                    fix = fix or f
            innermost, nd = nd, best
        if not fix:
            for s in ast.walk(innermost):      # 2-D cell write ⇒ DP/matrix fill
                tgts = (s.targets if isinstance(s, ast.Assign)
                        else [s.target] if isinstance(s, (ast.AugAssign, ast.AnnAssign)) else [])
                for t in tgts:
                    if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Subscript):
                        fix = INHERENT_FIX
                        break
        return " × ".join(parts), fix

    def collect_calls(node, factor, out, own):
        """Call sites with the loop factor in force at each — the interprocedural edges.

        The node itself is inspected on entry, not just its children: a call that IS
        a comprehension's element expression (`[find_user(u, o) for o in orders]`) is
        never anybody's child in that walk, and was silently dropped.

        Each loop's ITERABLE is walked at the OUTER factor — it is evaluated once,
        not per iteration — so a costly call there is not multiplied.
        """
        if isinstance(node, ast.Call):
            nm = None
            if isinstance(node.func, ast.Name):
                nm = node.func.id
            elif isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) \
                    and node.func.value.id in ("self", "cls"):
                nm = node.func.attr
            if nm and nm != own:
                out.append((nm, factor, node.lineno))

        if isinstance(node, _COMPS):
            deeper = cx_mul(factor, py_loop_size(node, ctx)[0])
            parts = ([node.key, node.value] if isinstance(node, ast.DictComp) else [node.elt])
            parts += [i for g in node.generators for i in g.ifs]
            for p in parts:
                collect_calls(p, deeper, out, own)
            for g in node.generators:
                collect_calls(g.iter, factor, out, own)
            return
        if isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
            deeper = cx_mul(factor, py_loop_size(node, ctx)[0])
            collect_calls(node.iter if isinstance(node, (ast.For, ast.AsyncFor)) else node.test,
                          factor if isinstance(node, (ast.For, ast.AsyncFor)) else deeper,
                          out, own)
            for p in list(node.body) + list(node.orelse):
                collect_calls(p, deeper, out, own)
            return
        for ch in ast.iter_child_nodes(node):
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            collect_calls(ch, factor, out, own)

    infos = []
    for fn in [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        info = FnInfo(path, (path, fn.lineno), fn.name, fn.lineno)
        roots = py_child_loops(fn)
        for r in roots:
            total = price(r)
            if cx_max(info.self_cost, total) != info.self_cost:
                info.self_cost = info.total = total
                info.worst_line = r.lineno
                info.chain, fx = chain(r)
                info.fix = fx or "pre-index the inner collection into a dict/set before the loop"
            for nd, _size, _why, ev, _kids, _best in list(ev_store.values()):
                for kind, ln, txt, sev, msg, f in ev:
                    if kind in ("io", "await", "shift", "concat", "sort", "copy", "regex"):
                        fs.append(F(path, ln, "bigo", sev,
                                    "%s: `%s` inside the loop at line %d" % (msg, txt, nd.lineno), f))
            ev_store.clear()
        collect_calls(fn, CONST, info.calls, fn.name)
        infos.append(info)

        # recursion
        selfcalls = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
                     and isinstance(n.func, ast.Name) and n.func.id == fn.name]
        if len(selfcalls) >= 2:
            memo = any(d for d in fn.decorator_list if "cache" in py_name(d).lower()) or \
                any(w in ast.dump(fn) for w in ("memo", "cache", "seen", "visited", " dp"))
            if not memo:
                fs.append(F(path, fn.lineno, "bigo", "high",
                            "%s — est. O(2^n): %d self-calls per invocation and no memo table"
                            % (fn.name, len(selfcalls)),
                            "memoize (`@functools.cache`) or rewrite bottom-up — this recomputes the same subproblems"))
    return dedupe(fs), infos


def py_bounds(path, src, tree, ctx):
    fs = []
    lines = src.splitlines()

    for n in ast.walk(tree):
        if isinstance(n, ast.For) and isinstance(n.iter, ast.Call) and \
                isinstance(n.iter.func, ast.Name) and n.iter.func.id == "range" and isinstance(n.target, ast.Name):
            var = n.target.id
            args = n.iter.args
            last = args[-1] if len(args) < 3 else args[1]
            base = None
            if isinstance(last, ast.BinOp) and isinstance(last.op, ast.Add) and \
                    isinstance(last.right, ast.Constant) and last.right.value == 1 and \
                    isinstance(last.left, ast.Call) and isinstance(last.left.func, ast.Name) and last.left.func.id == "len":
                base = py_name(last.left.args[0]) if last.left.args else None
                if base and _indexes(n, base, var, plus=0):
                    fs.append(F(path, n.lineno, "bounds", "certain",
                                "`range(len(%s) + 1)` indexes `%s[%s]` — IndexError on the last step" % (base, base, var),
                                "drop the `+ 1`; `range(len(%s))` already covers every index" % base))
            if isinstance(last, ast.Call) and isinstance(last.func, ast.Name) and last.func.id == "len" and last.args:
                base = py_name(last.args[0])
                if _indexes(n, base, var, plus=1):
                    fs.append(F(path, n.lineno, "bounds", "high",
                                "reads `%s[%s + 1]` while ranging to `len(%s)` — IndexError on the final step"
                                % (base, var, base),
                                "range to `len(%s) - 1`, or zip the pairs: `zip(%s, %s[1:])`" % (base, base, base)))
                for other in _other_indexed(n, base, var):
                    fs.append(F(path, n.lineno, "bounds", "high",
                                "indexes `%s[%s]` but the range is `len(%s)` — IndexError if `%s` is shorter"
                                % (other, var, base, other),
                                "iterate `zip(%s, %s)`, or bound by `min(len(%s), len(%s))`" % (base, other, base, other)))

        if isinstance(n, ast.For) and isinstance(n.iter, ast.Call) and \
                isinstance(n.iter.func, ast.Name) and n.iter.func.id == "enumerate" and \
                len(n.iter.args) > 1 and isinstance(n.iter.args[1], ast.Constant) and n.iter.args[1].value == 1 and \
                isinstance(n.target, ast.Tuple) and n.target.elts and isinstance(n.target.elts[0], ast.Name):
            var, base = n.target.elts[0].id, py_name(n.iter.args[0])
            if _indexes(n, base, var, plus=0):
                fs.append(F(path, n.lineno, "bounds", "certain",
                            "`enumerate(%s, 1)` starts the index at 1 but `%s[%s]` still indexes from 0"
                            % (base, base, var),
                            "use `enumerate(%s)` for indexing, and add 1 only where you DISPLAY the number" % base))

        if isinstance(n, ast.While):
            names = {x.id for x in ast.walk(n.test) if isinstance(x, ast.Name)}
            # A call in the test can advance state on its own (`while q.pop()`), so
            # termination is not provable — same silence rule as the JS side.
            if names and not isinstance(n.test, ast.Constant) and \
                    not any(isinstance(x, ast.Call) for x in ast.walk(n.test)):
                mutated = set()
                for s in ast.walk(n):
                    if isinstance(s, ast.AugAssign) and isinstance(s.target, ast.Name):
                        mutated.add(s.target.id)
                    if isinstance(s, ast.Assign):
                        for t in s.targets:
                            for x in ast.walk(t):
                                if isinstance(x, ast.Name):
                                    mutated.add(x.id)
                    if isinstance(s, ast.Call):
                        if isinstance(s.func, ast.Attribute):
                            mutated.add(py_name(s.func.value).split(".")[0])
                        for a in s.args:      # a callee can mutate what it is handed
                            if isinstance(a, ast.Name):
                                mutated.add(a.id)
                    if isinstance(s, (ast.Break, ast.Return, ast.Raise, ast.Await, ast.Yield)):
                        mutated |= names
                if not (names & mutated):
                    fs.append(F(path, n.lineno, "bounds", "certain",
                                "`while` never updates %s in its body and has no break — infinite loop"
                                % " / ".join(sorted(names)),
                                "advance the condition variable, or add the exit you meant"))

        if isinstance(n, (ast.For, ast.AsyncFor)) and isinstance(n.iter, ast.Name):
            coll = n.iter.id
            for s in ast.walk(n):
                if isinstance(s, ast.Call) and isinstance(s.func, ast.Attribute) and \
                        isinstance(s.func.value, ast.Name) and s.func.value.id == coll and \
                        s.func.attr in ("remove", "pop", "append", "insert", "clear"):
                    fs.append(F(path, s.lineno, "bounds", "certain",
                                "`%s.%s()` mutates the list being iterated — the iterator skips elements"
                                % (coll, s.func.attr),
                                "iterate a copy (`for x in list(%s)`) or build a new list and reassign" % coll))
                    break

        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for d in list(n.args.defaults) + [x for x in n.args.kw_defaults if x is not None]:
                if isinstance(d, (ast.List, ast.Dict, ast.Set)):
                    fs.append(F(path, n.lineno, "bounds", "certain",
                                "mutable default argument in `%s` — the SAME object is reused across every call" % n.name,
                                "default to None and build the container inside the function"))
                    break

        if isinstance(n, ast.Compare) and len(n.ops) == 1 and isinstance(n.ops[0], (ast.Gt, ast.GtE)):
            l = n.left
            if isinstance(l, ast.Call) and isinstance(l.func, ast.Attribute) and l.func.attr in ("find", "index_of"):
                c = n.comparators[0]
                if isinstance(c, ast.Constant) and ((isinstance(n.ops[0], ast.Gt) and c.value == 0) or
                                                    (isinstance(n.ops[0], ast.GtE) and c.value == 1)):
                    fs.append(F(path, n.lineno, "bounds", "certain",
                                "`.find(...) > 0` misses a match at index 0",
                                "compare against -1: `.find(...) != -1`"))

        if isinstance(n, ast.ExceptHandler):
            body = n.body
            if len(body) == 1 and isinstance(body[0], ast.Pass):
                fs.append(F(path, n.lineno, "bounds", "high",
                            "`except: pass` swallows the failure — the caller cannot tell success from silence",
                            "log with context and re-raise, or return an explicit error value"))

        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "zip" and \
                len(n.args) >= 2 and not any(k.arg == "strict" for k in n.keywords):
            fs.append(F(path, n.lineno, "bounds", "medium",
                        "`zip()` without `strict=` silently truncates to the shortest input — length mismatches vanish",
                        "pass `strict=True` (3.10+) if the inputs must be the same length"))

    cmps = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Compare) and len(n.ops) == 1 and \
                isinstance(n.ops[0], (ast.Lt, ast.LtE, ast.Gt, ast.GtE)):
            op = {ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">="}[type(n.ops[0])]
            cmps.append((py_name(n.left), op, py_name(n.comparators[0]), n.lineno))
    fs += cmp_inconsistency(path, "", None, py_cmps=[(l, o, r, ln) for l, o, r, ln in cmps])
    return dedupe(fs)


def _indexes(node, base, var, plus=0):
    for s in ast.walk(node):
        if isinstance(s, ast.Subscript) and py_name(s.value) == base:
            idx = s.slice
            if plus == 0 and isinstance(idx, ast.Name) and idx.id == var:
                return True
            if plus and isinstance(idx, ast.BinOp) and isinstance(idx.op, ast.Add) and \
                    isinstance(idx.left, ast.Name) and idx.left.id == var and \
                    isinstance(idx.right, ast.Constant) and idx.right.value == plus:
                return True
    return False


def _other_indexed(node, base, var):
    out = set()
    for s in ast.walk(node):
        if isinstance(s, ast.Subscript) and isinstance(s.slice, ast.Name) and s.slice.id == var:
            nm = py_name(s.value)
            if nm != base and "." not in nm and nm not in ("self",):
                out.add(nm)
    return sorted(out)


def py_fluff(path, src, tree):
    fs = []
    lines = src.splitlines()

    for fn in [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        dumped = ast.dump(fn)
        if "locals" in dumped or "eval" in dumped or "exec" in dumped:
            continue
        loads, stores = set(), {}
        for n in ast.walk(fn):
            if isinstance(n, ast.Name):
                if isinstance(n.ctx, ast.Load):
                    loads.add(n.id)
                elif isinstance(n.ctx, ast.Store):
                    stores.setdefault(n.id, n.lineno)
            if isinstance(n, (ast.Global, ast.Nonlocal)):
                loads |= set(n.names)
            if isinstance(n, ast.Attribute):
                loads.add(py_name(n).split(".")[0])
        for nm, ln in stores.items():
            if nm not in loads and not nm.startswith("_"):
                fs.append(F(path, ln, "fluff", "medium",
                            "`%s` is assigned in %s and never read" % (nm, fn.name),
                            "delete it, and whatever exists only to produce it", 1))

        body = fn.body
        if body and isinstance(body[-1], ast.Return) and isinstance(body[-1].value, ast.Name) and len(body) >= 2:
            prev = body[-2]
            if isinstance(prev, ast.Assign) and len(prev.targets) == 1 and \
                    isinstance(prev.targets[0], ast.Name) and prev.targets[0].id == body[-1].value.id:
                fs.append(F(path, prev.lineno, "fluff", "low",
                            "`%s` is assigned then immediately returned" % body[-1].value.id,
                            "return the expression directly", 1))

        for n in ast.walk(fn):
            if isinstance(n, ast.If) and len(n.body) == 1 and len(n.orelse) == 1 and \
                    isinstance(n.body[0], ast.Return) and isinstance(n.orelse[0], ast.Return) and \
                    isinstance(n.body[0].value, ast.Constant) and isinstance(n.orelse[0].value, ast.Constant) and \
                    {n.body[0].value.value, n.orelse[0].value.value} == {True, False}:
                neg = "" if n.body[0].value.value is True else "not "
                fs.append(F(path, n.lineno, "fluff", "medium",
                            "if/return True/False is just the condition",
                            "`return %s(%s)`" % (neg, ast.unparse(n.test)), 3))
            if isinstance(n, ast.ExceptHandler) and len(n.body) == 1 and isinstance(n.body[0], ast.Raise) and \
                    n.body[0].exc is not None and isinstance(n.body[0].exc, ast.Name) and n.name == n.body[0].exc.id:
                fs.append(F(path, n.lineno, "fluff", "medium",
                            "except that re-raises unchanged does nothing",
                            "delete the try/except — the exception already propagates", 3))

        depth = _max_depth(fn)
        if depth >= 5:
            fs.append(F(path, fn.lineno, "fluff", "medium",
                        "`%s` nests %d levels deep" % (fn.name, depth),
                        "invert the conditions into guard clauses and return early", 0))

    comments = [(i + 1, l.split("#", 1)[1]) for i, l in enumerate(lines)
                if l.strip().startswith("#") and "#" in l]
    fs += comment_fluff(path, src, comments)
    return dedupe(fs)


def _max_depth(fn, node=None, d=0):
    node = fn if node is None else node
    best = d
    for ch in ast.iter_child_nodes(node):
        if isinstance(ch, (ast.If, ast.For, ast.While, ast.With, ast.Try, ast.AsyncFor, ast.AsyncWith)):
            best = max(best, _max_depth(fn, ch, d + 1))
        elif not isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef)):
            best = max(best, _max_depth(fn, ch, d))
    return best


# ───────────────────────────────────────────────────────────────── driver ───


def dedupe(fs):
    seen, out = set(), []
    for f in fs:
        k = (f.path, f.line, f.kind, f.msg)
        if k not in seen:
            seen.add(k)
            out.append(f)
    return out


def analyze(path, modes):
    """→ (findings, [FnInfo]). Function costs come back UNpropagated: a call's cost
    can only be resolved once every file in the run has been collected."""
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return [], []
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return [], []
    ext = os.path.splitext(path)[1].lower()
    if ext not in SRC_EXT:
        return [], []
    fs, infos = [], []
    if ext == ".py":
        try:
            tree = ast.parse(src)
        except SyntaxError:
            return [], []                  # unparsable → say nothing, never guess
        ctx = PyCtx(tree)
        if "bigo" in modes:
            more, infos = py_bigo(path, tree, ctx)
            fs += more
        if "bounds" in modes:
            fs += py_bounds(path, src, tree, ctx)
        if "fluff" in modes:
            fs += py_fluff(path, src, tree)
    else:
        masked, comments = js_mask(src)
        starts = line_index(src)
        if "bigo" in modes:
            more, infos = js_bigo(path, src, masked, starts)
            fs += more
        if "bounds" in modes:
            fs += js_bounds(path, src, masked, starts)
        if "fluff" in modes:
            fs += js_fluff(path, src, masked, starts, comments)
    return dedupe(fs), infos


def parse_ranges(spec):
    out = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            try:
                out.append((int(a), int(b)))
            except ValueError:
                # A malformed range in a user-supplied --lines spec is skipped so
                # the rest of the spec still applies; refusing the whole scan over
                # one bad token would be worse than ignoring it.
                pass
        elif part.isdigit():
            out.append((int(part), int(part)))
    return out


def main(argv):
    if len(argv) < 3 or argv[1] not in ("bigo", "bounds", "fluff", "all"):
        print(__doc__)
        return 1
    cmd = argv[1]
    modes = ("bigo", "bounds", "fluff") if cmd == "all" else (cmd,)
    files, ranges, min_sev, as_json, quiet, no_context = [], [], "medium", False, False, False
    i = 2
    while i < len(argv):
        a = argv[i]
        if a == "--lines" and i + 1 < len(argv):
            ranges = parse_ranges(argv[i + 1]); i += 2
        elif a == "--min-sev" and i + 1 < len(argv):
            min_sev = argv[i + 1]; i += 2
        elif a == "--json":
            as_json = True; i += 1
        elif a == "--quiet":
            quiet = True; i += 1
        elif a == "--no-context":
            no_context = True; i += 1
        elif a.startswith("--"):
            print("unknown option %r" % a)
            return 1
        else:
            files.append(a); i += 1
    if min_sev not in SEV_ORDER:
        print("--min-sev must be one of: %s" % ", ".join(SEV_ORDER))
        return 1

    # TARGETS are what gets reported; CONTEXT exists only so a call out of a target
    # resolves. With --lines the caller (the edit gate) names its own context, so the
    # first file is the target. Otherwise siblings are discovered automatically —
    # because a model running this by hand will not think to pass them, and without
    # them a cross-file O(n²) reads as clean. Measured live: serge ran the checker on
    # one file, got "clean", and reported O(n) for code that was O(n²).
    targets = [files[0]] if (ranges and files) else list(files)
    context = list(files[1:]) if (ranges and files) else []
    if not no_context and len(targets) <= 4:
        seen = {os.path.abspath(p) for p in targets} | {os.path.abspath(p) for p in context}
        for t in targets:
            try:
                d = os.path.dirname(os.path.abspath(t)) or "."
                for nm in sorted(os.listdir(d)):
                    p = os.path.join(d, nm)
                    if p in seen or os.path.splitext(nm)[1].lower() not in SRC_EXT:
                        continue
                    if os.path.isfile(p) and os.path.getsize(p) < 400_000:
                        context.append(p)
                        seen.add(p)
                    if len(context) >= AUTO_CONTEXT_CAP:
                        break
            except OSError:
                # Context gathering is best-effort: an unreadable directory means
                # less context, never a failed scan of the file we were asked about.
                pass

    findings, scanned_lines, all_fns = [], 0, []
    ctx_modes = tuple(m for m in modes if m == "bigo")
    for p in targets:
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                scanned_lines += fh.read().count("\n") + 1
        except OSError:
            continue
        more, infos = analyze(p, modes)
        findings += more
        all_fns += infos
    # Context files contribute function COSTS only — computing their bounds/fluff
    # would be discarded anyway.
    if ctx_modes:
        for p in context:
            all_fns += analyze(p, ctx_modes)[1]
    # Interprocedural pass — across EVERY file in this run, so a helper defined in
    # one file and called inside a loop in another is priced correctly. Pass more
    # files in one invocation and the analysis gets sharper, never wronger.
    if all_fns:
        findings += bigo_findings(propagate(all_fns))
    findings = dedupe(findings)

    tset = {os.path.abspath(p) for p in targets}
    findings = [f for f in findings if os.path.abspath(f.path) in tset]
    if ranges:
        findings = [f for f in findings if any(a <= f.line <= b for a, b in ranges)]
    findings = [f for f in findings if SEV_ORDER[f.sev] >= SEV_ORDER[min_sev]]
    findings.sort(key=lambda f: (-SEV_ORDER[f.sev], f.path, f.line))

    removable = sum(f.cost for f in findings)
    if as_json:
        print(json.dumps({
            "findings": [f.as_dict() for f in findings],
            "summary": {"files": len(files), "lines": scanned_lines,
                        "findings": len(findings), "removable_lines": removable,
                        "removable_pct": round(100.0 * removable / scanned_lines, 1) if scanned_lines else 0.0},
        }, indent=1))
    elif not quiet:
        for f in findings:
            print("%s:%d  %s/%s  %s" % (f.path, f.line, f.kind, f.sev, f.msg))
            if f.fix:
                print("%s   → %s" % (" " * (len(f.path) + len(str(f.line)) + 2), f.fix))
        if findings:
            extra = ("  ·  ~%d line%s removable (%.0f%% of %d scanned)"
                     % (removable, "" if removable == 1 else "s",
                        100.0 * removable / scanned_lines if scanned_lines else 0, scanned_lines)) if removable else ""
            print("\n%d finding%s%s" % (len(findings), "" if len(findings) == 1 else "s", extra))
        else:
            print("clean at severity >= %s (%d lines scanned)" % (min_sev, scanned_lines))
    return 2 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
