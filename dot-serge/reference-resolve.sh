#!/usr/bin/env bash
# Serge reference resolver — UserPromptSubmit hook ($0, no LLM, no network).
#
# WHY THIS EXISTS (measured on an OS-image repo, 2026-07-29):
# the user asked for an env skeleton for Serge on a new OS image. Serge invented
# a variable list, twice, and when it wanted to know what "the Serge .env" looks
# like it ran a WEB SEARCH — for an unrelated product that shares the name —
# while the canonical answer sat on this disk the whole time:
#   $HOME/programs/serge-0.1.0/.env.example   (21 KB, every real key)
# Four corrections later the user had to name the file themselves.
#
# The failure is not laziness, it's that the workhorse seat has no cheap way to
# know that a word in the prompt ("serge", "router.env") is a REAL PATH on this
# machine. Telling it to "look first" (CONSTITUTION line 141) does not survive a
# weak seat. So instead of instructing, this hook does the lookup itself and
# hands over the answer as fact, before the model's first tool call:
#
#   1. PATHS named in the prompt   → exists? size/lines? or MISSING + the real
#                                    file of that name in this workspace.
#   2. OTHER PROJECTS named        → absolute path, one-line identity from
#                                    package.json/README, its config templates,
#                                    and its live config dir. Only for projects
#                                    that are NOT the one you're standing in —
#                                    cross-project references are where the
#                                    guessing happens.
#   3. TEMPLATE requests           → when the prompt asks for a skeleton /
#                                    example / boilerplate of a config family,
#                                    the existing files of that family in this
#                                    workspace, with key counts.
#
# Costs nothing on a prompt that names no path, no other project, and no
# template — it prints nothing and the turn is unchanged.
#
# Safety:
#   1. Off-switch: SERGE_REFRESOLVE_DISABLE=1
#   2. Read-only, local-only. Never prints file CONTENTS — paths, sizes and key
#      COUNTS only, so a live config dir can be cited without leaking secrets.
#   3. Bounded: 1.5s walk deadline, 20k dirs, output capped ~1600 chars.
#   4. Fail open (silent) on any error.
#
# Wired in ~/.serge/settings.json as UserPromptSubmit.
set -uo pipefail

[ "${SERGE_REFRESOLVE_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the model, not the harness: resolving the paths a task names is
# precisely the work some golden tasks exist to test.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, time, glob

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"
prompt = re.sub(_WRAPPERS, " ", str(d.get("prompt") or ""), flags=re.S).strip()
if not prompt or len(prompt) > 20000:
    sys.exit(0)

root = os.path.abspath(os.path.expanduser(str(d.get("cwd") or ".")))
HOME = os.path.expanduser("~")

SKIP = {
    ".git", "node_modules", "dist", "build", "out", ".venv", "venv",
    "__pycache__", ".next", ".nuxt", ".cache", "target", "vendor", ".turbo",
    ".mypy_cache", ".pytest_cache", ".tox", ".ruff_cache", "coverage",
    "site-packages", ".terraform", ".gradle", ".idea", ".svelte-kit",
}

_index = None


def workspace_index():
    """basename -> [abs paths], bounded. Built at most once, only if needed."""
    global _index
    if _index is not None:
        return _index
    idx = {}
    deadline = time.time() + 1.5
    seen = 0
    try:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            dirnames[:] = [x for x in dirnames if x not in SKIP]
            for fn in filenames:
                idx.setdefault(fn, []).append(os.path.join(dirpath, fn))
            seen += 1
            if seen > 20000 or time.time() > deadline:
                break
    except Exception:
        pass
    _index = idx
    return idx


def sizestr(p):
    try:
        sz = os.path.getsize(p)
    except Exception:
        return ""
    return "%.1f KB" % (sz / 1024.0) if sz >= 1024 else "%d B" % sz


def keycount(p):
    """KEY= lines, INCLUDING commented-out ones. serge's own .env.example is
    21 KB of documentation with 124 commented keys and exactly 1 live one —
    counting only live lines reported '1 key' and made the canonical template
    look empty, which is the opposite of the point."""
    try:
        with open(p, "r", errors="ignore") as fh:
            return sum(
                1
                for ln in fh
                if re.match(r"^\s*#?\s*[A-Za-z_][A-Za-z0-9_]*\s*=", ln)
            )
    except Exception:
        return 0


def linecount(p):
    try:
        with open(p, "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0


# ---------------------------------------------------------------- 1. paths ---
PATH_RE = re.compile(r"(?<![\w~@])((?:~|\.{1,2})?/[A-Za-z0-9._/@\-]{2,})")
FILE_RE = re.compile(
    r"(?<![\w./\-])((?:\.[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)*)|"
    r"(?:[A-Za-z0-9_\-]+\.(?:env|example|sample|skel|template|tmpl|sh|bash|zsh|"
    r"ts|tsx|js|jsx|mjs|cjs|py|rb|go|rs|java|c|h|cpp|json|jsonl|md|ya?ml|toml|"
    r"ini|conf|cfg|service|timer|socket|lock|txt|sql|csv|tsv|env)))(?![\w/])"
)

# The most explicit path form in this vocabulary — "$SERGE_HOME/router.env", the
# spelling used throughout serge's own README, INSTALL docs and test fixtures —
# expanded to nothing, so the one way a user can name a config file UNAMBIGUOUSLY
# was the one way that never resolved. Expand only the two vars that name real
# roots, and only for path scanning: the project-name matcher below keeps the RAW
# prompt, so an expanded home directory cannot manufacture a spurious project hit.
def _expand_roots(text):
    sh = os.environ.get("SERGE_HOME") or os.path.join(HOME, ".serge")
    for var, val in (("SERGE_HOME", sh), ("HOME", HOME)):
        text = re.sub(r"\$\{%s\}|\$%s\b" % (var, var), lambda _m, v=val: v, text)
    return text


scan = _expand_roots(prompt)

path_lines = []
seen_paths = set()
for m in PATH_RE.finditer(scan):
    tok = m.group(1).rstrip(".,;:!?)]}>'\"")
    if len(tok) < 5 or (tok.count("/") < 2 and "." not in os.path.basename(tok)):
        continue
    ap = os.path.abspath(os.path.expanduser(tok))
    if ap in seen_paths:
        continue
    seen_paths.add(ap)
    if os.path.isdir(ap):
        try:
            n = len(os.listdir(ap))
        except Exception:
            n = 0
        path_lines.append("  %s — directory, %d entries" % (ap, n))
    elif os.path.isfile(ap):
        extra = ""
        kc = keycount(ap) if re.search(r"env", os.path.basename(ap), re.I) else 0
        if kc:
            extra = ", %d keys" % kc
        path_lines.append(
            "  %s — EXISTS (%s, %d lines%s)" % (ap, sizestr(ap), linecount(ap), extra)
        )
    else:
        alt = [p for p in workspace_index().get(os.path.basename(ap), []) if p != ap]
        if alt:
            path_lines.append(
                "  %s — DOES NOT EXIST. That name does exist here: %s"
                % (ap, ", ".join(alt[:3]))
            )
        else:
            path_lines.append("  %s — DOES NOT EXIST (no file by that name in this workspace)" % ap)
    if len(path_lines) >= 6:
        break

# Relative multi-segment paths ("src/api/client.ts") — the commonest way a person
# names a file, and the absolute-path pattern above misses all of them. Resolved
# against cwd; reported ONLY when it resolves or its basename exists somewhere, so
# "and/or" and "24/7" can never produce a line.
REL_RE = re.compile(r"(?<![\w./~\-])([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+)(?![\w/])")
if len(path_lines) < 6:
    for m in REL_RE.finditer(scan):
        tok = m.group(1).rstrip(".,;:!?)]}>'\"")
        if "://" in tok or tok in seen_paths or len(tok) < 5:
            continue
        ap = os.path.join(root, tok)
        base = os.path.basename(tok)
        if os.path.isfile(ap) or os.path.isdir(ap):
            seen_paths.add(tok)
            kind = "directory" if os.path.isdir(ap) else "EXISTS (%s, %d lines)" % (
                sizestr(ap), linecount(ap)
            )
            path_lines.append("  %s → %s — %s" % (tok, ap, kind))
        elif "." in base:
            alt = workspace_index().get(base, [])
            if alt:
                seen_paths.add(tok)
                path_lines.append(
                    "  %s — NOT at that path. That name exists here: %s"
                    % (tok, ", ".join(alt[:3]))
                )
        if len(path_lines) >= 6:
            break

# bare filenames (no slash): resolve by basename inside the workspace
if len(path_lines) < 6:
    for m in FILE_RE.finditer(prompt):
        tok = m.group(1)
        if len(tok) < 4 or tok in seen_paths:
            continue
        hits = workspace_index().get(tok, [])
        if not hits:
            continue
        seen_paths.add(tok)
        extra = ""
        if re.search(r"env", tok, re.I):
            kc = keycount(hits[0])
            if kc:
                extra = ", %d keys" % kc
        path_lines.append(
            "  %s → %s (%s%s)%s"
            % (
                tok,
                hits[0],
                sizestr(hits[0]),
                extra,
                "" if len(hits) == 1 else " [+%d more with this name]" % (len(hits) - 1),
            )
        )
        if len(path_lines) >= 6:
            break

# ------------------------------------------------------------- 2. projects ---
GENERIC = {
    "programs", "projects", "project", "code", "work", "src", "bin", "docs",
    "doc", "test", "tests", "tmp", "temp", "build", "dist", "node", "home",
    "config", "data", "lib", "apps", "app", "web", "api", "main", "master",
}


def norm(name):
    return re.sub(r"[-_.]?v?\d+([.\-]\d+)*$", "", name.lower()).strip("-_.")


# candidate projects: ~/programs/* plus ~/.<name> config dirs
#
# SCAN DEPTH: a single listdir only sees projects sitting DIRECTLY in ~/programs.
# The moment that directory is grouped — category folders, an archive folder, a
# monorepo wrapper — every real project drops one level below this listing and
# the names people actually type stop resolving, silently: the prompt simply
# loses its project-grounding block, with no error anywhere. norm() already
# strips version suffixes, so "foo-1.2.3" -> "foo" matches once it is VISIBLE;
# the bug is purely one of depth. Two passes, so top-level names keep precedence
# over nested ones; both are bounded listdir+isdir, no recursion.
PROGRAMS = os.path.join(HOME, "programs")
candidates = {}
try:
    for entry in sorted(os.listdir(PROGRAMS)):
        p = os.path.join(PROGRAMS, entry)
        if os.path.isdir(p):
            candidates.setdefault(norm(entry), []).append(p)
except Exception:
    pass
try:
    _nested = {}
    for entry in sorted(os.listdir(PROGRAMS)):
        p = os.path.join(PROGRAMS, entry)
        if entry.startswith(".") or entry in SKIP or not os.path.isdir(p):
            continue
        for sub in sorted(os.listdir(p))[:200]:
            if sub.startswith(".") or sub in SKIP:
                continue
            sp = os.path.join(p, sub)
            if os.path.isdir(sp):
                _nested.setdefault(norm(sub), []).append(sp)
    for k, v in _nested.items():
        candidates.setdefault(k, []).extend(v)   # top-level entries stay first
except Exception:
    pass

# which project are we standing in? (never resolve that one — no new info)
here = set()
cur = root
while cur and cur != "/" and cur != HOME:
    here.add(norm(os.path.basename(cur)))
    cur = os.path.dirname(cur)

words = set(re.findall(r"[A-Za-z][A-Za-z0-9_\-]{2,}", prompt.lower()))
words |= {w.rstrip("s") for w in words if w.endswith("s")}  # "serges" -> "serge"

proj_blocks = []
for name in sorted(words):
    if name in GENERIC or name in here or len(name) < 4:
        continue
    dirs = candidates.get(name)
    if not dirs:
        continue
    for pdir in dirs[:1]:
        ident = ""
        pj = os.path.join(pdir, "package.json")
        if os.path.isfile(pj):
            try:
                with open(pj, errors="ignore") as fh:
                    j = json.load(fh)
                ident = str(j.get("description") or j.get("name") or "")[:110]
            except Exception:
                pass
        if not ident:
            for rd in ("README.md", "README", "readme.md"):
                rp = os.path.join(pdir, rd)
                if os.path.isfile(rp):
                    try:
                        with open(rp, errors="ignore") as fh:
                            for ln in fh:
                                ln = ln.strip().lstrip("#").strip()
                                if len(ln) > 8 and not ln.startswith(("!", "[", "<", "-")):
                                    ident = ln[:110]
                                    break
                    except Exception:
                        pass
                    break
        block = ["  %s → %s%s" % (name, pdir, (" — " + ident) if ident else "")]
        tmpl = []
        for pat in (".env*", "*.example", "*.sample", "*.template", "*/.env*"):
            try:
                tmpl.extend(glob.glob(os.path.join(pdir, pat)))
            except Exception:
                pass
        tmpl = sorted({t for t in tmpl if os.path.isfile(t)})
        for t in tmpl[:3]:
            kc = keycount(t)
            block.append(
                "      config template: %s (%s%s)"
                % (t, sizestr(t), (", %d keys" % kc) if kc else "")
            )
        cfg = os.path.join(HOME, "." + name)
        if os.path.isdir(cfg) and cfg != pdir:
            block.append(
                "      live config dir: %s — real values live here; read it for FORMAT only, never copy values into a repo, image, or reply"
                % cfg
            )
        proj_blocks.append("\n".join(block))
    if len(proj_blocks) >= 3:
        break

# ------------------------------------------------------------ 3. templates ---
WANT_TEMPLATE = re.compile(
    r"\b(skeleton|skel|template|boilerplate|scaffold|stub|starter|"
    r"example file|sample file|blank copy|empty (?:copy|version))\b", re.I
)
ARTIFACT = re.compile(
    r"\b(env(?:ironment)?[ \-]?(?:var\w*|file)?|\.env|dotenv|api[ \-]?keys?|"
    r"dockerfile|docker[ \-]?compose|systemd|unit file|service file|"
    r"config(?:uration)? file|settings file|ci|workflow)\b", re.I
)
FAMILY = {
    "env": (
        re.compile(r"^(\.env([._-].*)?|env([._-].*)?\.(example|sample|skel|template|tmpl|dist)|.*\.env)$", re.I),
        re.compile(r"\b(env|dotenv|api[ \-]?key|secret)", re.I),
    ),
    "docker": (
        re.compile(r"^(Dockerfile.*|docker-compose.*\.ya?ml|compose\.ya?ml)$", re.I),
        re.compile(r"\bdocker", re.I),
    ),
    "systemd": (
        re.compile(r"^.*\.(service|timer|socket|mount)$", re.I),
        re.compile(r"\b(systemd|unit file|service file)\b", re.I),
    ),
}

tmpl_lines = []
if WANT_TEMPLATE.search(prompt) and ARTIFACT.search(prompt):
    idx = workspace_index()
    for fam, (fre, pre) in FAMILY.items():
        if not pre.search(prompt):
            continue
        hits = []
        for fn, paths in idx.items():
            if fre.match(fn):
                hits.extend(paths)
        for p in sorted(set(hits))[:4]:
            kc = keycount(p)
            tmpl_lines.append(
                "  %s (%s%s)" % (p, sizestr(p), (", %d keys" % kc) if kc else "")
            )

# ---------------------------------------------------------------- output -----
if not (path_lines or proj_blocks or tmpl_lines):
    sys.exit(0)

out = [
    "<system-reminder>",
    "Filesystem facts, resolved just now by a local hook — not recalled, not guessed. "
    "Use these exact paths; do not invent variants of them, and Read before you write.",
]
if path_lines:
    out.append("\nReferences in your prompt:")
    out.extend(path_lines)
if proj_blocks:
    out.append("\nOther projects named (you are NOT standing in these):")
    out.extend(proj_blocks)
    out.append(
        "  If you need to know how one of these is configured, read the file — a project name is "
        "not a web-search topic, and a same-named product online is a different thing."
    )
if tmpl_lines:
    out.append("\nThe workspace already ships artifacts of the kind you were asked to create:")
    out.extend(tmpl_lines)
    out.append(
        "  Follow the closest one's names and format instead of authoring a fresh list from memory."
    )
out.append("</system-reminder>")

ctx = "\n".join(out)
if len(ctx) > 1600:
    ctx = ctx[:1580].rstrip() + "\n… (truncated)\n</system-reminder>"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
exit 0
