#!/usr/bin/env python3
"""
archscan — computes known-bad architecture from the import graph and source.

This is the engine behind arch-gate.sh and plan-gate.sh. It is a library plus a
CLI, so the gates stay thin and the checks are testable on their own.

WHY COMPUTED AND NOT ASKED. A gate that greps a plan for "Security:" is defeated
by writing "Security: N/A". Everything here is derived from the code itself:
Tarjan over the import graph, a structural walk of the source. A model cannot
predict its way past a cycle it actually created.

SCOPE. Findings are reported for the files named on the command line (what the
edit touched). Graph-level facts are computed over the whole repo, because a
cycle is a property of the graph and not of one file — but only cycles THROUGH a
touched file are reported. Being told about a legacy module's coupling is noise;
being told about the cycle you closed thirty seconds ago is a fix.

LANGUAGES. JS/TS and Python get the full check set. Anything else degrades to
the graph-level checks it can support rather than reporting false confidence.

Every threshold is a calibrated opinion, not a theorem, and lives in THRESHOLDS
so it can be tuned per repo via env without editing logic.
"""

import ast
import json
import os
import re
import sys

# ── thresholds — calibrated opinions, overridable per repo ───────────────────
def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


THRESHOLDS = {
    "fanout": _env_int("SERGE_ARCH_FANOUT", 18),
    "cyclomatic": _env_int("SERGE_ARCH_CYCLO", 15),
    "nesting": _env_int("SERGE_ARCH_NESTING", 5),
    "func_lines": _env_int("SERGE_ARCH_FUNC_LINES", 120),
    "arity": _env_int("SERGE_ARCH_ARITY", 6),
    "god_loc": _env_int("SERGE_ARCH_GOD_LOC", 600),
    "god_exports": _env_int("SERGE_ARCH_GOD_EXPORTS", 20),
}

SRC_EXT = {".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts", ".py"}
PRUNE = {
    "node_modules", ".git", "dist", "build", "out", "target", "vendor",
    ".next", ".nuxt", ".venv", "venv", "__pycache__", ".cache", "coverage",
    ".runs", ".serge",
}
TEST_RE = re.compile(r"(^|[./_-])(test|tests|spec|__tests__)([./_-]|$)", re.I)
ENTRY_RE = re.compile(
    r"(^|/)(index|main|cli|app|server|setup|conftest|__init__|__main__)\.[a-z]+$", re.I
)
# NOT "tools/" — that is a production directory as often as a developer one
# (a tool registry, a plugin dir). Including it marked every tool module in
# serge-engine self-referential because its own registry lives in tools/.
# Only directories that are unambiguously developer-side belong here.
SCRIPTISH_RE = re.compile(
    r"(^|/)(scripts|bin|examples?|benchmarks?|fixtures?|templates?|scaffold\w*)/", re.I)


def is_test(path):
    return bool(TEST_RE.search(path))


def lang_of(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".py":
        return "py"
    if ext in SRC_EXT:
        return "js"
    return None


# ═══════════════════════════════════════════════════════════════════════════
# repo walk + import graph
# ═══════════════════════════════════════════════════════════════════════════

def walk(root, limit=20000):
    """Directory-level pruning: the cost avoided is the readdir, not the compare."""
    out = []
    stack = [root]
    while stack and len(out) < limit:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            if e.is_dir(follow_symlinks=False):
                if e.name in PRUNE or e.name.startswith("."):
                    continue
                stack.append(e.path)
            elif e.is_file(follow_symlinks=False):
                if os.path.splitext(e.name)[1].lower() in SRC_EXT:
                    out.append(e.path)
    return out


JS_IMPORT = re.compile(
    r"""(?:^|\s)import\s+(?:[\w*{}\n\r\t, ]+\s+from\s+)?["']([^"']+)["']"""
    r"""|(?:^|\W)require\s*\(\s*["']([^"']+)["']\s*\)"""
    r"""|(?:^|\s)export\s+(?:\*|\{[^}]*\})\s+from\s+["']([^"']+)["']"""
    r"""|(?:^|\W)import\s*\(\s*["']([^"']+)["']\s*\)""",
    re.M,
)

JS_RESOLVE_EXT = ["", ".ts", ".tsx", ".mts", ".js", ".mjs", ".cjs", ".jsx",
                  "/index.ts", "/index.js", "/index.mjs"]


def resolve_js(spec, from_file, root):
    """Relative specifiers only. A bare specifier is a package, not our graph."""
    if not spec.startswith("."):
        return None
    base = os.path.normpath(os.path.join(os.path.dirname(from_file), spec))
    for ext in JS_RESOLVE_EXT:
        cand = base + ext
        if os.path.isfile(cand):
            return os.path.realpath(cand)
        # .js in source often means .ts on disk (ESM-style TS imports)
        if ext == "" and base.endswith(".js"):
            for alt in (".ts", ".tsx", ".mts"):
                c2 = base[:-3] + alt
                if os.path.isfile(c2):
                    return os.path.realpath(c2)
    return None


def resolve_py(mod, level, from_file, root):
    if level:                                   # relative import
        base = os.path.dirname(from_file)
        for _ in range(level - 1):
            base = os.path.dirname(base)
        parts = mod.split(".") if mod else []
    else:
        base = root
        parts = mod.split(".") if mod else []
    if not parts:
        return None
    cand = os.path.join(base, *parts)
    for suffix in (".py", "/__init__.py"):
        p = cand + suffix
        if os.path.isfile(p):
            return os.path.realpath(p)
    return None


def build_graph(root, files=None):
    """-> (edges: {file: set(file)}, sources: {file: text})"""
    root = os.path.realpath(root)
    files = files if files is not None else walk(root)
    files = [os.path.realpath(f) for f in files]
    known = set(files)
    edges = {f: set() for f in files}
    sources = {}

    for f in files:
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        sources[f] = src
        lang = lang_of(f)

        if lang == "js":
            for m in JS_IMPORT.finditer(src):
                spec = next((g for g in m.groups() if g), None)
                if not spec:
                    continue
                tgt = resolve_js(spec, f, root)
                if tgt and tgt in known:
                    edges[f].add(tgt)
        elif lang == "py":
            try:
                tree = ast.parse(src)
            except SyntaxError:
                continue
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for a in node.names:
                        tgt = resolve_py(a.name, 0, f, root)
                        if tgt and tgt in known:
                            edges[f].add(tgt)
                elif isinstance(node, ast.ImportFrom):
                    tgt = resolve_py(node.module or "", node.level or 0, f, root)
                    if tgt and tgt in known:
                        edges[f].add(tgt)
                    # `from . import x` and `from .pkg import x`: the imported
                    # NAME may itself be a module, not an attribute. Resolving
                    # only node.module misses `from . import x` entirely — it
                    # carries module="" — which is one of the commonest forms in
                    # a Python package, so the graph silently lost those edges.
                    for a in node.names:
                        sub = ((node.module + ".") if node.module else "") + a.name
                        t2 = resolve_py(sub, node.level or 0, f, root)
                        if t2 and t2 in known:
                            edges[f].add(t2)

    for f in edges:
        edges[f].discard(f)                     # self-import is not a cycle
    return edges, sources


# ═══════════════════════════════════════════════════════════════════════════
# Tarjan — strongly connected components. Iterative: a deep import chain must
# not take the gate down with a RecursionError.
# ═══════════════════════════════════════════════════════════════════════════

def sccs(edges):
    index = {}
    low = {}
    on = {}
    stack = []
    out = []
    counter = [0]

    for root_node in edges:
        if root_node in index:
            continue
        work = [(root_node, iter(sorted(edges.get(root_node, ()))))]
        index[root_node] = low[root_node] = counter[0]
        counter[0] += 1
        stack.append(root_node)
        on[root_node] = True

        while work:
            node, it = work[-1]
            advanced = False
            for nxt in it:
                if nxt not in index:
                    index[nxt] = low[nxt] = counter[0]
                    counter[0] += 1
                    stack.append(nxt)
                    on[nxt] = True
                    work.append((nxt, iter(sorted(edges.get(nxt, ())))))
                    advanced = True
                    break
                if on.get(nxt):
                    low[node] = min(low[node], index[nxt])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index[node]:
                comp = []
                while True:
                    w = stack.pop()
                    on[w] = False
                    comp.append(w)
                    if w == node:
                        break
                if len(comp) > 1:
                    out.append(comp)
    return out


# ═══════════════════════════════════════════════════════════════════════════
# source-level checks
# ═══════════════════════════════════════════════════════════════════════════


BROAD_EXC = {"Exception", "BaseException", "object"}


def _except_name(node):
    """Render the except clause for the message."""
    t = node.type
    if t is None:
        return "(bare)"
    try:
        return ast.unparse(t)
    except Exception:
        return getattr(t, "id", "?")


def _except_is_broad(node):
    """A bare `except:` or one naming Exception/BaseException catches everything."""
    t = node.type
    if t is None:
        return True
    names = []
    if isinstance(t, ast.Tuple):
        names = [getattr(e, "id", "") for e in t.elts]
    else:
        names = [getattr(t, "id", "") or getattr(t, "attr", "")]
    return any(n in BROAD_EXC for n in names)


JUSTIFY_MIN_WORDS = 4


def _has_justification(src, start_line, end_line):
    """
    Look for a substantive comment on, just above, or inside the handler.

    Read from the raw source because Python discards comments at parse time.
    A token count is the cheapest proxy for substance available: "# ignore"
    explains nothing, "# a malformed range is skipped, not fatal" does.
    """
    lines = src.splitlines()
    lo = max(0, start_line - 3)
    hi = min(len(lines), end_line + 1)
    for raw in lines[lo:hi]:
        if "#" not in raw:
            continue
        body = raw.split("#", 1)[1].strip()
        if len([w for w in re.split(r"\W+", body) if w]) >= JUSTIFY_MIN_WORDS:
            return True
    return False


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


F = lambda sev, kind, path, line, msg, fix: {
    "severity": sev, "kind": kind, "file": path, "line": line, "msg": msg, "fix": fix,
}

# —— JS/TS regex checks. Regex, not a parser: no JS AST is available in stdlib
# python, and a wrong-but-loud finding on a real pattern beats no finding. Each
# is written to under-report rather than over-report.
JS_EMPTY_CATCH = re.compile(r"catch\s*(?:\([^)]*\))?\s*\{\s*\}", re.M)
# A catch whose entire body is a comment: allowed, but the comment must say something.
JS_TOKEN_CATCH = re.compile(
    r"catch\s*(?:\([^)]*\))?\s*\{\s*((?://[^\n]*|/\*(?:[^*]|\*(?!/))*\*/)\s*)+\}", re.M)
JS_LOG_ONLY_CATCH = re.compile(
    r"catch\s*\(([A-Za-z_$][\w$]*)\)\s*\{\s*console\.\w+\([^;\n]*\);?\s*\}", re.M)
JS_FETCH = re.compile(r"\b(?:fetch|axios\.\w+|https?\.request)\s*\(", re.M)
JS_TIMEOUT_HINT = re.compile(r"signal|timeout|AbortController|AbortSignal", re.I)
# NOT .map/.filter/.reduce: chaining them is SEQUENTIAL passes over the same
# data — O(n) total, not nesting. Treating a chain as a loop reported
# `.split().map().filter().some()` as O(n*m), which it is not.
JS_FIND_IN_LOOP = re.compile(r"\b(?:for|while)\s*\(|\.forEach\s*\(", re.M)
JS_LINEAR_SCAN = re.compile(r"\.(?:find|findIndex|includes|indexOf|some)\s*\(", re.M)
JS_QUERY = re.compile(
    r"\b(?:query|execute|findOne|findMany|findAll|select|aggregate|"
    r"getOne|getMany|fetchOne|fetchAll)\s*\(", re.I)
JS_FUNC = re.compile(
    r"(?:^|\W)(?:function\s+([A-Za-z_$][\w$]*)|"
    r"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\()", re.M)
JS_EXPORT = re.compile(r"^\s*export\s+(?:default\s+)?(?:const|let|var|function|class|async)", re.M)
JS_BRANCH = re.compile(r"\b(?:if|for|while|case|catch|&&|\|\||\?)\b|\?\?")
JS_ASSERT = re.compile(
    r"\b(?:expect|assert|should|chai|t\.(?:is|deepEqual|truthy)|"
    r"strictEqual|deepStrictEqual|toBe|toEqual|toThrow|ok\()", re.I)
JS_TEST_BLOCK = re.compile(
    r"\b(?:it|test)\s*\(\s*['\"`](.+?)['\"`]\s*,\s*(?:async\s*)?\(?[^)]*\)?\s*=>\s*\{", re.M)



JS_RETRY_SAFE = re.compile(
    r"(?://|/\*|\*)[^\n]*\b(?:safe to (?:re-?issue|retry)|idempotent|does not mutate|"
    r"non-?mutating|no side ?effects?|nothing to duplicate)\b", re.I)


def _js_retry_justified(src):
    """A comment explicitly claiming the retried call is safe to re-issue."""
    return bool(JS_RETRY_SAFE.search(src))


def js_checks(path, src, out):
    # swallowed errors
    # JS catch is always broad — there is no narrow clause — so an empty one is
    # high unless it carries a real justification. JS_EMPTY_CATCH only matches a
    # body of pure whitespace, so a comment already suppresses it; this second
    # pass makes sure the comment actually says something.
    for m in JS_EMPTY_CATCH.finditer(src):
        out.append(F("high", "swallowed-error", path, line_of(src, m.start()),
                     "catch block is empty — every failure is discarded and the caller is "
                     "told it succeeded",
                     "handle it, re-throw it, or leave a comment saying why discarding it is correct"))
    for m in JS_TOKEN_CATCH.finditer(src):
        body = m.group(1)
        words = [w for w in re.split(r"\W+", re.sub(r"[/*]", " ", body)) if w]
        if len(words) < JUSTIFY_MIN_WORDS:
            out.append(F("medium", "swallowed-error", path, line_of(src, m.start()),
                         "catch block discards the error behind a comment that explains "
                         "nothing (%r)" % body.strip()[:40],
                         "say why discarding it is correct, or handle it"))
    for m in JS_LOG_ONLY_CATCH.finditer(src):
        out.append(F("medium", "swallowed-error", path, line_of(src, m.start()),
                     "catch only logs and continues — execution proceeds as if nothing failed",
                     "re-throw, return an error result, or state why continuing is correct"))

    # unbounded network
    for m in JS_FETCH.finditer(src):
        window = src[max(0, m.start() - 200): m.start() + 400]
        if not JS_TIMEOUT_HINT.search(window):
            out.append(F("high", "unbounded-resource", path, line_of(src, m.start()),
                         "network call with no timeout or abort signal — it can hang forever",
                         "pass an AbortSignal with a timeout"))

    # N+1 and O(n^2) lookups: scan each loop body
    for lm in JS_FIND_IN_LOOP.finditer(src):
        body = src[lm.end(): lm.end() + 600]
        q = JS_QUERY.search(body)
        if q:
            out.append(F("high", "n-plus-1", path, line_of(src, lm.start()),
                         "query call inside a loop — N+1 round trips",
                         "batch the query outside the loop, or use a join / IN clause"))
        # A scan over a STRING LITERAL is O(1) on a constant — `'.+^$'.includes(c)`
        # is a character-class test, not a lookup into a collection that grows.
        s = next((mm for mm in JS_LINEAR_SCAN.finditer(body)
                  if not re.search(r"['\"`][^'\"`\n]{0,80}['\"`]\s*$",
                                   body[:mm.start()])), None)
        if s and not q:
            out.append(F("medium", "wrong-container", path, line_of(src, lm.start()),
                         "linear scan (.find/.includes/.indexOf) inside a loop — O(n*m)",
                         "build a Map or Set once before the loop for O(1) lookup"))

    # function-level complexity
    for m in JS_FUNC.finditer(src):
        name = m.group(1) or m.group(2) or "anonymous"
        brace = src.find("{", m.end() - 1)
        if brace == -1:
            continue
        depth, i, maxd = 0, brace, 0
        while i < len(src):
            c = src[i]
            if c == "{":
                depth += 1
                maxd = max(maxd, depth)
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = src[brace:i]
        lines = body.count("\n")
        cyclo = len(JS_BRANCH.findall(body)) + 1
        if cyclo > THRESHOLDS["cyclomatic"]:
            out.append(F("medium", "complexity", path, line_of(src, m.start()),
                         "%s() cyclomatic complexity ~%d (limit %d) — more paths than tests can cover"
                         % (name, cyclo, THRESHOLDS["cyclomatic"]),
                         "extract the branches into named functions"))
        if lines > THRESHOLDS["func_lines"]:
            out.append(F("low", "long-function", path, line_of(src, m.start()),
                         "%s() is ~%d lines (limit %d)" % (name, lines, THRESHOLDS["func_lines"]),
                         "split it along its internal seams"))
        if maxd > THRESHOLDS["nesting"] + 1:
            out.append(F("low", "deep-nesting", path, line_of(src, m.start()),
                         "%s() nests ~%d deep (limit %d)" % (name, maxd - 1, THRESHOLDS["nesting"]),
                         "use early returns to flatten"))

    # unhandled rejection: a .then chain with no .catch/.finally
    for m in JS_THEN.finditer(src):
        chain = src[m.start(): m.start() + 400]
        stop = chain.find("\n\n")
        if stop != -1:
            chain = chain[:stop]
        if not JS_CATCH_CHAIN.search(chain):
            out.append(F("medium", "unhandled-rejection", path, line_of(src, m.start()),
                         "promise chain with no .catch — a rejection escapes this call path silently",
                         "add .catch, or await inside try/catch"))

    # writes without a transaction boundary
    writes = list(JS_WRITE_CALL.finditer(src))
    if len(writes) >= 2 and not JS_TXN.search(src):
        out.append(F("high", "no-transaction", path, line_of(src, writes[0].start()),
                     "%d write operations with no transaction boundary — a partial failure "
                     "leaves inconsistent state" % len(writes),
                     "wrap the writes in a transaction, or state why partial application is safe"))

    # Retry on a non-idempotent verb with no idempotency key.
    #
    # The scanner cannot tell a payment POST from a completion POST, and the
    # difference is the whole finding: retrying the first duplicates a charge,
    # retrying the second costs tokens. So an explicit, substantive statement
    # that the call is safe to re-issue settles it — the same contract used for
    # a scoped `except: pass`. A key, or a stated reason, or the finding stands.
    if JS_RETRY.search(src) and JS_POST.search(src) and not JS_IDEMPOTENCY.search(src):
        m = JS_POST.search(src)
        if not _js_retry_justified(src):
            out.append(F("high", "missing-idempotency", path, line_of(src, m.start()),
                         "retry logic around a POST/PATCH with no idempotency key and no "
                         "stated reason it is safe to re-issue — a retried non-idempotent "
                         "write duplicates data",
                         "send an Idempotency-Key header, make the endpoint idempotent, or "
                         "state in a comment why re-issuing this request cannot duplicate anything"))

    # mutating route with no authz on the path
    for m in JS_ROUTE_MUT.finditer(src):
        window = src[m.start(): m.start() + 500]
        if not JS_AUTHZ.search(window):
            out.append(F("high", "unauthorized-mutation", path, line_of(src, m.start()),
                         "mutating route %s has no visible authorization check" % m.group(1)[:40],
                         "add the authz middleware or an explicit check before the handler body"))

    # user-controlled value reaching a dangerous sink
    if JS_TAINT_SRC.search(src):
        for m in JS_SINK.finditer(src):
            window = src[max(0, m.start() - 400): m.end() + 200]
            if JS_TAINT_SRC.search(window):
                out.append(F("high", "trust-boundary", path, line_of(src, m.start()),
                             "user-controlled input reaches a command/query sink without a "
                             "visible sanitization step",
                             "parameterize the query, or validate against an allowlist"))
                break

    # Unindexed filter column. Requires REAL SQL context: "where E = edits" in a
    # complexity docblock is English prose, and matching it reported a full table
    # scan in a file with no database in it.
    has_sql = re.search(r"\b(?:SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b", src, re.I)
    for m in (SQL_WHERE.finditer(src) if has_sql else ()):
        head = src[src.rfind("\n", 0, m.start()) + 1:m.start()].lstrip()
        if head.startswith(("//", "*", "#")):
            continue                     # inside a comment
        col = m.group(1).split(".")[-1]
        if col.lower() in ("id", "1"):
            continue
        if not re.search(r"(?:INDEX|index)[^\n]*\b%s\b" % re.escape(col), src, re.I):
            out.append(F("medium", "unindexed-filter", path, line_of(src, m.start()),
                         "query filters on '%s' with no index declared in this file — a full "
                         "scan on a table that will grow" % col,
                         "add an index, or confirm the table stays small"))
            break

    # tests that cannot fail
    if is_test(path):
        for m in JS_TEST_BLOCK.finditer(src):
            brace = src.find("{", m.end() - 1)
            if brace == -1:
                continue
            depth, i = 0, brace
            while i < len(src):
                if src[i] == "{":
                    depth += 1
                elif src[i] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = src[brace:i]
            if not JS_ASSERT.search(body):
                out.append(F("high", "test-cannot-fail", path, line_of(src, m.start()),
                             'test "%s" contains no assertion — it passes no matter what the code does'
                             % m.group(1)[:60],
                             "assert on the actual observed value"))


def py_checks(path, src, out):
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        out.append(F("high", "syntax", path, e.lineno or 1,
                     "file does not parse: %s" % e.msg, "fix the syntax error"))
        return

    for node in ast.walk(tree):
        # Swallowed errors, graded by the BLAST RADIUS of the except clause.
        #
        # `except Exception: pass` discards everything — including the TypeError
        # from the bug you just wrote. No comment makes that safe, so it stays
        # high regardless.
        #
        # `except ValueError: pass` is a scoped, deliberate decision. It is
        # correct often enough that flagging it unconditionally would fire on
        # good code forever, so a substantive comment settles it — the same
        # contract as `# noqa: <reason>` or `eslint-disable-next-line`. The
        # comment must be REAL (>= 4 words): "# ignore" buys nothing.
        #
        # The comment has to be read from the SOURCE, not the tree: Python drops
        # comments during parsing, so a check that only walks the AST is
        # demanding a justification it structurally cannot see. That was the bug
        # here until 2026-08-22 — the remedy the gate printed could not satisfy it.
        if isinstance(node, ast.ExceptHandler):
            body = node.body
            swallows = len(body) == 1 and isinstance(body[0], ast.Pass)
            logs_only = bool(body) and all(
                isinstance(s, ast.Expr) and isinstance(s.value, ast.Call)
                and isinstance(s.value.func, ast.Attribute)
                and s.value.func.attr in ("print", "debug", "info", "warning")
                for s in body)

            if swallows or logs_only:
                broad = _except_is_broad(node)
                verb = "is a bare pass" if swallows else "only logs and continues"
                if broad:
                    out.append(F("high", "swallowed-error", path, node.lineno,
                                 "except %s %s — this catches EVERY error, including bugs "
                                 "in the try body, and the caller is told it succeeded"
                                 % (_except_name(node), verb),
                                 "narrow the clause to the errors you actually expect "
                                 "(e.g. except (ValueError, OSError)), then handle or re-raise"))
                elif not _has_justification(src, node.lineno, node.end_lineno or node.lineno):
                    out.append(F("medium", "swallowed-error", path, node.lineno,
                                 "except %s %s with no stated reason — scoped, but the next "
                                 "reader cannot tell deliberate from forgotten"
                                 % (_except_name(node), verb),
                                 "add a comment saying why discarding this is correct, "
                                 "or handle it"))

        # function complexity
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            cyclo = 1
            maxd = 0

            def depth_walk(n, d=0):
                nonlocal cyclo, maxd
                maxd = max(maxd, d)
                for ch in ast.iter_child_nodes(n):
                    if isinstance(ch, (ast.If, ast.For, ast.While, ast.ExceptHandler,
                                       ast.With, ast.Assert, ast.BoolOp, ast.IfExp)):
                        cyclo += 1
                        depth_walk(ch, d + 1)
                    else:
                        depth_walk(ch, d)

            depth_walk(node)
            if cyclo > THRESHOLDS["cyclomatic"]:
                out.append(F("medium", "complexity", path, node.lineno,
                             "%s() cyclomatic complexity ~%d (limit %d)"
                             % (node.name, cyclo, THRESHOLDS["cyclomatic"]),
                             "extract branches into named functions"))
            nargs = len(node.args.args) + len(node.args.kwonlyargs)
            if nargs > THRESHOLDS["arity"]:
                out.append(F("low", "arity", path, node.lineno,
                             "%s() takes %d parameters (limit %d)"
                             % (node.name, nargs, THRESHOLDS["arity"]),
                             "group related parameters into a dataclass or dict"))
            if maxd > THRESHOLDS["nesting"]:
                out.append(F("low", "deep-nesting", path, node.lineno,
                             "%s() nests %d deep (limit %d)"
                             % (node.name, maxd, THRESHOLDS["nesting"]),
                             "use early returns to flatten"))

            if is_test(path) and node.name.startswith("test"):
                has_assert = any(
                    isinstance(n, ast.Assert)
                    or (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                        and n.func.attr.startswith("assert"))
                    or (isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                        and n.func.id.startswith("assert"))
                    for n in ast.walk(node)
                )
                if not has_assert:
                    out.append(F("high", "test-cannot-fail", path, node.lineno,
                                 "%s() contains no assertion — it passes no matter what the code does"
                                 % node.name,
                                 "assert on the actual observed value"))

        # N+1 / linear scan inside loops
        if isinstance(node, (ast.For, ast.While)):
            for inner in ast.walk(node):
                if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Attribute):
                    if inner.func.attr in ("execute", "query", "fetchone", "fetchall",
                                           "get", "filter", "find_one", "find"):
                        if inner.func.attr in ("execute", "query", "fetchone",
                                               "fetchall", "find_one"):
                            out.append(F("high", "n-plus-1", path, inner.lineno,
                                         "query call inside a loop — N+1 round trips",
                                         "batch outside the loop or use a join / IN clause"))
                            break
                if isinstance(inner, ast.Compare) and any(
                    isinstance(o, ast.In) for o in inner.ops
                ):
                    tgt = inner.comparators[0] if inner.comparators else None
                    if isinstance(tgt, (ast.List, ast.Tuple)) or (
                        isinstance(tgt, ast.Name) and tgt.id.endswith(("list", "array", "items"))
                    ):
                        out.append(F("medium", "wrong-container", path, inner.lineno,
                                     "membership test against a list inside a loop — O(n*m)",
                                     "convert to a set once before the loop for O(1)"))
                        break


def is_entrypoint(path, src):
    """Filename convention, a shebang, or a __main__ guard — all mean 'run me'."""
    if ENTRY_RE.search(path):
        return True
    if src.startswith("#!"):
        return True
    return bool(re.search(r'if\s+__name__\s*==\s*[\'"]__main__[\'"]', src)
                or re.search(r"import\.meta\.url\s*===\s*`file://\$\{process\.argv\[1\]\}`", src))



# A comment written to get PAST a gate rather than to explain the code. Observed
# live 2026-08-22: blocked on an empty catch, the model wrote
# `/* arch-gate-bypass */` beside it and announced it had "satisfied the checker
# requirements". The finding survived by luck — the comment sat outside the
# braces — so the behaviour is now named and flagged rather than left to chance.
#
# This is the one check whose subject is the model's INTENT, and it is
# deliberately narrow: it matches self-declared circumvention, not any mention of
# a gate. A comment explaining WHY code is correct never reads like this.
GAMING_RE = re.compile(
    r"(?://|/\*|\*|#)[^\n]*\b("
    r"(?:arch|algo|claims|plan|lint|type|semgrep)[-_ ]?(?:gate|check(?:er)?)[-_ ]?"
    r"(?:bypass|skip|ignore|silence|disable|workaround|hack)"
    r"|bypass(?:es|ing)?\s+(?:the\s+)?(?:gate|check|linter|scanner|hook)"
    r"|(?:to\s+)?(?:satisfy|appease|placate|shut\s*up|get\s+past|fool|trick)\s+"
    r"(?:the\s+)?(?:gate|checker|check|linter|scanner|hook|analyzer)"
    r"|silence\s+(?:the\s+)?(?:gate|checker|warning|hook)"
    r")\b", re.I)


# The scanner's own source and corpus necessarily contain every pattern it
# detects. Both markers are real definitions rather than casual mentions, so this
# is not an escape hatch anyone can add to a file to silence the check.
SELF_MARKERS = ("GAMING_RE = re.compile", "import archscan")


def gaming_checks(path, src, out):
    """Flag comments that exist to defeat a gate rather than explain the code."""
    if any(mk in src for mk in SELF_MARKERS):
        return
    for m in GAMING_RE.finditer(src):
        out.append(F("high", "gate-gaming", path, line_of(src, m.start()),
                     "this comment is written to get past a gate, not to explain the code "
                     "(%r)" % m.group(0).strip()[:70],
                     "the gate is reporting a real property of this code — fix the code, or "
                     "write a comment that says why the code is correct as it stands. A "
                     "comment whose purpose is circumvention is worse than the finding it "
                     "hides, because the next reader now trusts a green check that means "
                     "nothing"))


def module_checks(path, src, edges, fanin, importers, out):
    """Per-module structural facts."""
    lang = lang_of(path)
    loc = src.count("\n") + 1
    fanout = len(edges.get(path, ()))

    if fanout > THRESHOLDS["fanout"]:
        out.append(F("medium", "high-coupling", path, 1,
                     "fan-out is %d (limit %d) — this module has %d reasons to break"
                     % (fanout, THRESHOLDS["fanout"], fanout),
                     "extract a facade, or split the module along its seams"))

    exports = len(JS_EXPORT.findall(src)) if lang == "js" else len(
        [n for n in (ast.parse(src).body if _safe(src) else [])
         if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))])
    if loc > THRESHOLDS["god_loc"] and fanout > THRESHOLDS["fanout"] // 2 \
            and exports > THRESHOLDS["god_exports"]:
        out.append(F("high", "god-object", path, 1,
                     "god object: %d lines, fan-out %d, %d exports — it does everything "
                     "and everything depends on it" % (loc, fanout, exports),
                     "split by responsibility; each piece should have one reason to change"))

    # Migrations, and anything else loaded by a runner rather than imported, are
    # never orphans — the framework discovers them by directory convention.
    if (fanin.get(path, 0) == 0 and not is_test(path)
            and not is_entrypoint(path, src) and not MIGRATION_RE.search(path)
            and not SCRIPTISH_RE.search(path)):
        out.append(F("high", "orphan-module", path, 1,
                     "nothing imports this module and it is not an entrypoint — it is either "
                     "dead code or it was never wired in",
                     "wire it into the system, or delete it"))

    # Self-referential module: production code whose ONLY importers are its own
    # tests and scripts. The suite is grading fiction — nothing in the shipped
    # system exercises it, so every test can pass while the module is inert.
    # This is exactly the shape of serge-engine.ts (2026-08-22): 343 lines, zero
    # network calls, imported only by the three scripts written beside it.
    # A template or example is meant to be COPIED, not imported — its only
    # importer being its own test is the correct shape for one, not a smell.
    elif (not is_test(path) and not is_entrypoint(path, src)
            and not SCRIPTISH_RE.search(path)):
        imps = importers.get(path, set())
        if imps and all(is_test(i) or SCRIPTISH_RE.search(i) for i in imps):
            names = sorted(os.path.basename(i) for i in imps)[:4]
            out.append(F("high", "self-referential", path, 1,
                         "only tests/scripts import this module (%s) — no shipped code path "
                         "reaches it, so its tests prove nothing about the system"
                         % ", ".join(names),
                         "wire it into the production path, or delete it and its tests"))


def _safe(src):
    try:
        ast.parse(src)
        return True
    except SyntaxError:
        return False



# ═══════════════════════════════════════════════════════════════════════════
# graph-level architecture
# ═══════════════════════════════════════════════════════════════════════════

# Conventional layer order, low index = closest to the domain core. An edge from
# a LOW layer to a HIGH one is a violation: the core must not depend on the shell
# it is delivered through, or the domain cannot be tested or reused without it.
LAYERS = [
    (re.compile(r"(^|/)(domain|core|model|entities|types)/", re.I), 0),
    (re.compile(r"(^|/)(lib|util|utils|shared|common)/", re.I), 1),
    (re.compile(r"(^|/)(service|services|usecase|application|logic)/", re.I), 2),
    (re.compile(r"(^|/)(repo|repository|db|store|persistence|dal)/", re.I), 2),
    (re.compile(r"(^|/)(api|routes|controllers|handlers|http)/", re.I), 3),
    (re.compile(r"(^|/)(ui|views?|components?|pages?|screens?|ink|cli)/", re.I), 4),
]


def layer_of(path):
    for rx, n in LAYERS:
        if rx.search(path):
            return n
    return None


def graph_checks(root, targets, edges, fanin, sources, out):
    tset = set(targets)

    for src_file, deps in edges.items():
        if src_file not in tset:
            continue
        ls = layer_of(src_file)
        if ls is None:
            continue
        for dep in deps:
            ld = layer_of(dep)
            if ld is None or ld <= ls:
                continue
            out.append(F("high", "layering-violation", src_file, 1,
                         "layer inversion: %s imports %s — a lower layer depends on a higher "
                         "one, so the core cannot be tested or reused without the shell"
                         % (os.path.relpath(src_file, root), os.path.relpath(dep, root)),
                         "invert the dependency: pass what it needs in, or define the "
                         "interface in the lower layer and implement it in the higher one"))
            break

    # Instability vs abstractness — Martin's main sequence. A module that many
    # things depend on (low instability expected) but which itself depends on
    # many concrete things is the one whose churn propagates furthest.
    for f in targets:
        if f not in edges:
            continue
        ce = len(edges.get(f, ()))
        ca = fanin.get(f, 0)
        if ca + ce == 0:
            continue
        inst = ce / float(ca + ce)
        src = sources.get(f, "")
        # Abstractness proxy: interfaces/types/abstract declarations vs all decls.
        abstract = len(re.findall(r"\b(?:interface|type|abstract class|Protocol|ABC)\b", src))
        concrete = len(re.findall(r"\b(?:function|class|const|def)\b", src)) or 1
        a = min(1.0, abstract / float(concrete))
        dist = abs(a + inst - 1.0)
        if ca >= 4 and inst > 0.7 and dist > 0.6:
            out.append(F("medium", "instability", f, 1,
                         "%d module(s) depend on this, but it is itself unstable "
                         "(I=%.2f, A=%.2f, distance from main sequence %.2f) — its churn "
                         "propagates to every dependent" % (ca, inst, a, dist),
                         "depend on an abstraction here, or push the volatile parts out"))

    # Change amplification: the same symbol defined in several modules means one
    # conceptual change requires edits in all of them.
    DEF = re.compile(r"^\s*(?:export\s+)?(?:async\s+)?(?:function|class|def)\s+([A-Za-z_$][\w$]*)", re.M)
    where = {}
    for f, src in sources.items():
        for m in DEF.finditer(src):
            name = m.group(1)
            if len(name) < 6:                    # short names collide by chance
                continue
            where.setdefault(name, set()).add(f)
    for f in targets:
        src = sources.get(f, "")
        for m in DEF.finditer(src):
            name = m.group(1)
            homes = where.get(name, set())
            if len(homes) >= 3:
                out.append(F("medium", "change-amplification", f, line_of(src, m.start()),
                             "'%s' is defined in %d modules — one conceptual change to it "
                             "requires editing all of them" % (name, len(homes)),
                             "extract it to one module the others import"))
                break

    # Untested behaviour: a changed non-test module with no test anywhere naming it.
    test_files = [f for f in sources if is_test(f)]
    for f in targets:
        if (is_test(f) or ENTRY_RE.search(f) or MIGRATION_RE.search(f)
                or SCRIPTISH_RE.search(f)):
            continue
        stem = os.path.splitext(os.path.basename(f))[0]
        if any(stem in os.path.basename(t) or stem in sources.get(t, "") for t in test_files):
            continue
        out.append(F("medium", "untested-behaviour", f, 1,
                     "no test file references this module — the behaviour you just changed "
                     "has nothing asserting it still works",
                     "add a test that fails if this module misbehaves"))



# ═══════════════════════════════════════════════════════════════════════════
# verbosity — measured, not sensed
# ═══════════════════════════════════════════════════════════════════════════
#
# WHY A RATIO AND NOT A PATTERN LIST. algo-gate already names eight individual
# fluff patterns and never blocks on any of them, which is right: stopping a turn
# over one stray console.log costs more than the line it removes. But model-written
# code is not bulky because of one pattern — it is bulky because a dozen small
# ceremonies compound. The signal that matters is the FRACTION of the file that
# could be deleted without changing behaviour, and that is a number.
#
# The estimate is deliberately conservative: every pattern below is one a human
# reviewer would also call removable, and each carries an explicit line cost so
# the total is auditable rather than a vibe.
VERBOSITY_PCT = _env_int("SERGE_VERBOSITY_PCT", 18)
VERBOSITY_MIN_LINES = _env_int("SERGE_VERBOSITY_MIN_LINES", 25)

_V_JS = [
    (re.compile(r"^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[^;\n]+;?\s*\n\s*return\s+\1\s*;?", re.M),
     1, "assigned then immediately returned"),
    (re.compile(r"\}\s*else\s*\{", re.M), 0, None),        # placeholder, handled below
    (re.compile(r"(?:===\s*true|!==\s*false|==\s*true)\b", re.M),
     0, "redundant comparison to a boolean"),
    (re.compile(r"^\s*if\s*\([^)]+\)\s*\{\s*\n\s*return\s+(?:true|false)\s*;?\s*\n\s*\}\s*\n\s*return\s+(?:true|false)\s*;?", re.M),
     3, "if/return true/false is just the condition"),
    (re.compile(r"^\s*(?:async\s+)?function\s+\w+\s*\(([^)]*)\)\s*\{\s*\n\s*return\s+\w+\(\1\)\s*;?\s*\n\s*\}", re.M),
     3, "wrapper that forwards its arguments unchanged"),
    (re.compile(r"try\s*\{\s*\n(?:[^\n]*\n)?\s*\}\s*catch\s*\([^)]*\)\s*\{\s*\n\s*throw\s+\w+\s*;?\s*\n\s*\}", re.M),
     4, "try/catch that rethrows unchanged does nothing"),
]

_V_PY = [
    (re.compile(r"^\s*([A-Za-z_]\w*)\s*=\s*[^\n]+\n\s*return\s+\1\s*$", re.M),
     1, "assigned then immediately returned"),
    (re.compile(r"^\s*if\s+[^\n:]+:\s*\n\s*return\s+(?:True|False)\s*\n\s*return\s+(?:True|False)\s*$", re.M),
     2, "if/return True/False is just the condition"),
    (re.compile(r"(?:==\s*True|!=\s*False|is\s+True)\b", re.M),
     0, "redundant comparison to a boolean"),
]

_ELSE_AFTER_JUMP = re.compile(
    r"(?:return[^\n]*|throw[^\n]*|continue|break)\s*;?\s*\n\s*\}\s*else\s*\{", re.M)
_PY_ELSE_AFTER_JUMP = re.compile(
    r"^(\s*)(?:return|raise|continue|break)[^\n]*\n\1?else\s*:", re.M)
_ECHO_COMMENT = re.compile(r"^\s*(?://|#)\s*(.{4,60})\s*\n\s*([^\n]{4,})$", re.M)


def _dup_blocks(src, minlen=5):
    """Consecutive runs of >= minlen identical non-trivial lines appearing twice."""
    lines = [l.strip() for l in src.split("\n")]
    meaty = [i for i, l in enumerate(lines) if len(l) > 12 and not l.startswith(("//", "#", "*"))]
    seen, dupes = {}, 0
    for start in meaty:
        key = "\n".join(lines[start:start + minlen])
        if len(key) < 60:
            continue
        if key in seen:
            dupes += minlen
            seen[key] = None            # count each duplicate block once
        elif key not in seen:
            seen[key] = start
    return dupes


def _echo_comments(src):
    """Comments that restate the line under them — pure noise, and common."""
    n = 0
    for m in _ECHO_COMMENT.finditer(src):
        words = set(re.findall(r"[a-z]{4,}", m.group(1).lower()))
        code = set(re.findall(r"[a-z]{4,}", m.group(2).lower()))
        if words and len(words & code) >= max(1, len(words) // 2):
            n += 1
    return n


def verbosity_checks(path, src, out):
    lines = src.split("\n")
    total = len([l for l in lines if l.strip()])
    if total < VERBOSITY_MIN_LINES:
        return

    pats = _V_PY if lang_of(path) == "py" else _V_JS
    removable, detail = 0, []
    for rx, cost, label in pats:
        if label is None:
            continue
        n = len(rx.findall(src))
        if n:
            removable += n * max(cost, 1)
            detail.append("%s x%d" % (label, n))

    ej = len((_PY_ELSE_AFTER_JUMP if lang_of(path) == "py" else _ELSE_AFTER_JUMP).findall(src))
    if ej:
        removable += ej
        detail.append("else after return/throw x%d" % ej)

    dup = _dup_blocks(src)
    if dup:
        removable += dup
        detail.append("duplicated block(s) ~%d lines" % dup)

    ec = _echo_comments(src)
    if ec:
        removable += ec
        detail.append("comment restates the next line x%d" % ec)

    if not removable:
        return
    pct = 100.0 * removable / total
    sev = "high" if pct >= VERBOSITY_PCT else "low"
    out.append(F(sev, "verbosity", path, 1,
                 "~%d of %d lines (%.0f%%) are removable without changing behaviour: %s"
                 % (removable, total, pct, "; ".join(detail[:5])),
                 "delete them. Bulk is not free — it is more to read, more to keep true, "
                 "and more places for the next change to go wrong"))


# ═══════════════════════════════════════════════════════════════════════════
# migrations
# ═══════════════════════════════════════════════════════════════════════════


# —— reliability: promises, transactions, idempotency ————————————————————
JS_THEN = re.compile(r"\.then\s*\(")
JS_CATCH_CHAIN = re.compile(r"\.catch\s*\(|\.finally\s*\(")
JS_BARE_ASYNC = re.compile(
    r"^[ \t]*(?!(?:await|return|void|const|let|var|export|import|//|/\*|\*)\b)"
    r"([A-Za-z_$][\w$.]*)\s*\([^;\n]*\)\s*;?[ \t]*$", re.M)
JS_WRITE_CALL = re.compile(
    r"\.(?:insert|update|delete|save|create|remove|upsert|destroy|"
    r"insertOne|updateOne|deleteOne|insertMany|updateMany)\s*\(", re.I)
JS_TXN = re.compile(r"\b(?:transaction|beginTransaction|\$transaction|BEGIN|withTransaction|atomic)\b", re.I)
JS_RETRY = re.compile(r"\b(?:retry|retries|retryCount|backoff|attempts)\b", re.I)
JS_IDEMPOTENCY = re.compile(r"idempotenc|idempotent[-_]?key|Idempotency-Key", re.I)
JS_POST = re.compile(r"""method\s*:\s*['"](POST|PATCH)['"]|\.post\s*\(|\.patch\s*\(""", re.I)

# —— security ——————————————————————————————————————————————————————————
JS_ROUTE_MUT = re.compile(
    r"""\.(?:post|put|patch|delete)\s*\(\s*['"`]([^'"`]+)['"`]""", re.I)
JS_AUTHZ = re.compile(
    r"\b(?:auth|authenticate|authorize|requireUser|requireAuth|isAuthenticated|"
    r"checkPermission|can|guard|ensureLoggedIn|verifyToken|session\.user|req\.user)\b", re.I)
# NOT process.argv: whoever supplies argv already has a shell on this box, so
# there is no boundary being crossed and no privilege to escalate. Including it
# flagged every CLI that spawns what it was told to spawn.
JS_TAINT_SRC = re.compile(r"\b(?:req\.(?:body|query|params|headers)|request\.(?:body|query))\b")
JS_SINK = re.compile(
    r"\b(?:exec|execSync|spawn|spawnSync|eval|Function)\s*\(|"
    r"\.(?:query|raw|execute)\s*\(\s*[`'\"][^`'\"]*\$\{", re.I)

# —— sql ————————————————————————————————————————————————————————————————
# The \b must not follow "=" — both "=" and the space after it are non-word
# chars, so no boundary exists there and the whole pattern silently never fires.
SQL_WHERE = re.compile(r"\bWHERE\s+([A-Za-z_][\w.]*)\s*(?:=|<|>|\bLIKE\b|\bIN\b)", re.I)

MIGRATION_RE = re.compile(r"(^|/)(migrations?|migrate)(/|$)", re.I)
DOWN_RE = re.compile(r"\b(down|downgrade|rollback|revert)\b", re.I)
UP_RE = re.compile(r"\b(up|upgrade|forward)\b", re.I)


def migration_checks(path, src, out):
    if not MIGRATION_RE.search(path):
        return
    if UP_RE.search(src) and not DOWN_RE.search(src):
        out.append(F("high", "no-rollback", path, 1,
                     "migration defines an up path with no down/rollback — the change cannot "
                     "be reversed in production",
                     "add the inverse migration, or state in a comment why it is irreversible"))


# ═══════════════════════════════════════════════════════════════════════════
# entry point
# ═══════════════════════════════════════════════════════════════════════════

def scan(root, targets):
    root = os.path.realpath(root)
    all_files = walk(root)
    edges, sources = build_graph(root, all_files)

    fanin = {f: 0 for f in edges}
    importers = {f: set() for f in edges}
    for f, deps in edges.items():
        for d in deps:
            fanin[d] = fanin.get(d, 0) + 1
            importers.setdefault(d, set()).add(f)

    targets = [os.path.realpath(t) for t in targets if os.path.isfile(t)]
    tset = set(targets)
    out = []

    # graph-level: only cycles THROUGH a touched file
    for comp in sccs(edges):
        if tset & set(comp):
            names = [os.path.relpath(c, root) for c in sorted(comp)]
            hit = sorted(tset & set(comp))[0]
            out.append(F("high", "dependency-cycle", hit, 1,
                         "dependency cycle among %d modules: %s — ESM cycles resolve to "
                         "partially-initialised modules whose failure surfaces far from the cause"
                         % (len(comp), " -> ".join(names[:6]) + (" -> ..." if len(names) > 6 else "")),
                         "invert one edge: extract the shared piece, or inject the dependency"))

    graph_checks(root, targets, edges, fanin, sources, out)

    for t in targets:
        src = sources.get(t)
        if src is None:
            try:
                with open(t, "r", encoding="utf-8", errors="replace") as fh:
                    src = fh.read()
            except OSError:
                continue
        lang = lang_of(t)
        migration_checks(t, src, out)
        gaming_checks(t, src, out)
        verbosity_checks(t, src, out)
        if lang == "js":
            js_checks(t, src, out)
        elif lang == "py":
            py_checks(t, src, out)
        if lang:
            module_checks(t, src, edges, fanin, importers, out)

    rank = {"high": 0, "medium": 1, "low": 2}
    out.sort(key=lambda f: (rank.get(f["severity"], 3), f["file"], f["line"]))
    for f in out:
        f["file"] = os.path.relpath(f["file"], root)
    return out


def graph_facts(root):
    """For plan-gate's predictive check."""
    root = os.path.realpath(root)
    edges, _ = build_graph(root)
    return {
        "modules": len(edges),
        "edges": {os.path.relpath(k, root): sorted(os.path.relpath(v, root) for v in vs)
                  for k, vs in edges.items()},
        "cycles": [[os.path.relpath(c, root) for c in comp] for comp in sccs(edges)],
    }


def main(argv):
    if len(argv) < 2:
        print("usage: archscan.py <root> [file ...]   |   archscan.py --graph <root>",
              file=sys.stderr)
        return 64
    if argv[1] == "--graph":
        print(json.dumps(graph_facts(argv[2]), indent=1))
        return 0
    root = argv[1]
    targets = argv[2:] or walk(os.path.realpath(root))
    findings = scan(root, targets)
    print(json.dumps({"findings": findings, "count": len(findings)}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
