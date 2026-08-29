#!/usr/bin/env python3
"""
archscan test suite — a defect corpus plus a clean corpus.

TWO GUARANTEES, both learned the hard way this week:

  1. Every planted defect must be FOUND. A gate that misses the thing it exists
     to catch is worse than no gate, because a pass reads as assurance.

  2. `--self-test` runs the same corpus against a stub that reports NOTHING and
     asserts this suite FAILS. A suite that still passes when the scanner is
     removed is not testing the scanner. Three checks today passed or failed for
     the wrong reason; this is the guard against a fourth.

The clean corpus is equally load-bearing: a gate that blocks good code gets
disabled within a week and then protects nothing.
"""

import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import archscan  # noqa: E402


# ── corpus ──────────────────────────────────────────────────────────────────
# Each entry: (name, {relpath: source}, target relpath, expected kind or None)

DEFECTS = [
    ("dependency cycle", {
        "index.js": "import {a} from './a.js'\nexport const boot = () => a()\n",
        "a.js": "import {b} from './b.js'\nexport const a = () => b()\n",
        "b.js": "import {a} from './a.js'\nexport const b = () => a()\n",
    }, "a.js", "dependency-cycle"),

    ("orphan module", {
        "index.js": "export const boot = () => 1\n",
        "stranded.js": "export const nobodyImportsThis = () => 42\n",
    }, "stranded.js", "orphan-module"),

    ("empty catch (js)", {
        "index.js": "import './h.js'\n",
        "h.js": "export function h(){ try { risky() } catch (e) {} }\n",
    }, "h.js", "swallowed-error"),

    ("bare except pass (py)", {
        "__init__.py": "from . import h\n",
        "h.py": "def h():\n    try:\n        risky()\n    except Exception:\n        pass\n",
    }, "h.py", "swallowed-error"),

    ("fetch without timeout", {
        "index.js": "import './net.js'\n",
        "net.js": "export async function get(u){ const r = await fetch(u); return r.json() }\n",
    }, "net.js", "unbounded-resource"),

    ("Response shared between concurrent callers", {
        "index.js": "import './collapse.js'\n",
        "collapse.js": (
            "const inflight = new Map()\n"
            "export async function get(u){\n"
            "  let p = inflight.get(u)\n"
            "  if (!p) { p = fetch(u, { signal: AbortSignal.timeout(5000) }); inflight.set(u, p) }\n"
            "  const res = await p\n"
            "  return Buffer.from(await res.arrayBuffer())\n"
            "}\n"),
    }, "collapse.js", "shared-one-shot-body"),

    ("N+1 query in loop", {
        "index.js": "import './q.js'\n",
        "q.js": ("export async function load(ids){ const out=[]\n"
                 "  for (const id of ids) { const row = await db.query('select 1') ; out.push(row) }\n"
                 "  return out }\n"),
    }, "q.js", "n-plus-1"),

    ("linear scan in loop", {
        "index.js": "import './s.js'\n",
        "s.js": ("export function join(as, bs){ const out=[]\n"
                 "  for (const a of as) { const m = bs.find(b => b.id === a.id); out.push(m) }\n"
                 "  return out }\n"),
    }, "s.js", "wrong-container"),

    ("test with no assertion (js)", {
        "index.js": "export const f = () => 1\n",
        "f.test.js": "it('works', () => {\n  const r = f()\n  console.log(r)\n})\n",
    }, "f.test.js", "test-cannot-fail"),

    ("test with no assertion (py)", {
        "__init__.py": "from . import m\n",
        "m.py": "def f():\n    return 1\n",
        "test_m.py": "def test_works():\n    r = 1\n    print(r)\n",
    }, "test_m.py", "test-cannot-fail"),

    ("migration without rollback", {
        "index.js": "export const boot = () => 1\n",
        "migrations/001_add.js": "export function up(db){ db.addColumn('users','email') }\n",
    }, "migrations/001_add.js", "no-rollback"),

    ("self-referential module", {
        "index.js": "export const boot = () => 1\n",
        "engine.js": "export const createEngine = () => ({ run: () => 'simulated' })\n",
        "scripts/probe.js": "import {createEngine} from '../engine.js'\ncreateEngine().run()\n",
        "engine.test.js": "import {createEngine} from './engine.js'\nit('x',()=>{expect(createEngine()).toBeTruthy()})\n",
    }, "engine.js", "self-referential"),


    # ── added 2026-08-22: the checks promised in the published table ─────────
    ("layering violation", {
        "index.js": "import './domain/rule.js'\n",
        "domain/rule.js": "import {render} from '../ui/view.js'\nexport const rule = () => render()\n",
        "ui/view.js": "export const render = () => 1\n",
        "rule.test.js": "import {rule} from './domain/rule.js'\nit('x',()=>{expect(rule()).toBe(1)})\n",
    }, "domain/rule.js", "layering-violation"),

    ("unhandled rejection", {
        "index.js": "import './p.js'\n",
        "p.js": "export function go(){ fetch('/x', {signal: AbortSignal.timeout(1)}).then(r => r.json()) }\n",
        "p.test.js": "import {go} from './p.js'\nit('x',()=>{expect(go).toBeTruthy()})\n",
    }, "p.js", "unhandled-rejection"),

    ("writes without transaction", {
        "index.js": "import './w.js'\n",
        "w.js": ("export async function move(a,b){\n"
                 "  await db.update({id:a})\n"
                 "  await db.insert({id:b})\n}\n"),
        "w.test.js": "import {move} from './w.js'\nit('x',()=>{expect(move).toBeTruthy()})\n",
    }, "w.js", "no-transaction"),

    ("retry without idempotency key", {
        "index.js": "import './r.js'\n",
        "r.js": ("export async function send(p){ let retries = 3\n"
                 "  while (retries--) { await fetch('/pay', {method:'POST', body:p, "
                 "signal: AbortSignal.timeout(5000)}) } }\n"),
        "r.test.js": "import {send} from './r.js'\nit('x',()=>{expect(send).toBeTruthy()})\n",
    }, "r.js", "missing-idempotency"),

    ("mutating route without authz", {
        "index.js": "import './routes.js'\n",
        "routes.js": "export function wire(app){ app.post('/users/:id/delete', (req,res) => { res.end() }) }\n",
        "routes.test.js": "import {wire} from './routes.js'\nit('x',()=>{expect(wire).toBeTruthy()})\n",
    }, "routes.js", "unauthorized-mutation"),

    ("user input reaching a shell sink", {
        "index.js": "import './t.js'\n",
        "t.js": "export function run(req){ const name = req.body.name; return exec('ls ' + name) }\n",
        "t.test.js": "import {run} from './t.js'\nit('x',()=>{expect(run).toBeTruthy()})\n",
    }, "t.js", "trust-boundary"),

    ("unindexed filter column", {
        "index.js": "import './qq.js'\n",
        "qq.js": "export const byEmail = 'SELECT * FROM users WHERE email = ?'\n",
        "qq.test.js": "import {byEmail} from './qq.js'\nit('x',()=>{expect(byEmail).toBeTruthy()})\n",
    }, "qq.js", "unindexed-filter"),

    ("untested module", {
        "index.js": "import './lonely.js'\n",
        "lonely.js": "export const lonely = () => 1\n",
    }, "lonely.js", "untested-behaviour"),

    ("change amplification", {
        "index.js": "import './x1.js'\nimport './x2.js'\nimport './x3.js'\n",
        "x1.js": "export function calculateTaxRate(){ return 1 }\n",
        "x2.js": "export function calculateTaxRate(){ return 2 }\n",
        "x3.js": "export function calculateTaxRate(){ return 3 }\n",
        "x1.test.js": "import {calculateTaxRate} from './x1.js'\nit('x',()=>{expect(calculateTaxRate()).toBe(1)})\n",
        "x2.test.js": "import {calculateTaxRate} from './x2.js'\nit('x',()=>{expect(calculateTaxRate()).toBe(2)})\n",
        "x3.test.js": "import {calculateTaxRate} from './x3.js'\nit('x',()=>{expect(calculateTaxRate()).toBe(3)})\n",
    }, "x1.js", "change-amplification"),


    ("broad except:pass stays high even WITH a comment", {
        "__init__.py": "from . import b\n",
        "b.py": ("def h():\n    try:\n        risky()\n"
                 "    # this is deliberate and definitely safe to ignore here\n"
                 "    except Exception:\n        pass\n"),
        "test_b.py": "from .b import h\n\ndef test_h():\n    assert h() is None\n",
    }, "b.py", "swallowed-error"),

    ("narrow except:pass with NO reason", {
        "__init__.py": "from . import n\n",
        "n.py": "def h(x):\n    try:\n        return int(x)\n    except ValueError:\n        pass\n",
        "test_n.py": "from .n import h\n\ndef test_h():\n    assert h('a') is None\n",
    }, "n.py", "swallowed-error"),

    ("js catch with a hollow comment", {
        "index.js": "import './hollow.js'\n",
        "hollow.js": "export function h(){ try { risky() } catch (e) { /* ignore */ } }\n",
        "hollow.test.js": "import {h} from './hollow.js'\nit('x',()=>{expect(h).toBeTruthy()})\n",
    }, "hollow.js", "swallowed-error"),

    ("comment written to bypass a gate", {
        "index.js": "import './g.js'\n",
        "g.js": "export function h(){ return 1 } /* arch-gate-bypass */\n",
        "g.test.js": "import {h} from './g.js'\nit('x',()=>{expect(h()).toBe(1)})\n",
    }, "g.js", "gate-gaming"),

    ("comment written to satisfy the checker", {
        "__init__.py": "from . import gg\n",
        "gg.py": "def h():\n    # added to satisfy the checker, nothing more\n    return 1\n",
        "test_gg.py": "from .gg import h\n\ndef test_h():\n    assert h() == 1\n",
    }, "gg.py", "gate-gaming"),

    ("verbose code past the density threshold", {
        "index.js": "import './verbose.js'\n",
        "verbose.js": 'export function processUserRecords(records) {\n  // check if records is empty\n  if (records.length === 0) {\n    return []\n  }\n  const results = []\n  for (const record of records) {\n    // get the name from the record\n    const name = record.name\n    // get the email from the record\n    const email = record.email\n    if (record.active === true) {\n      const formatted = { name: name, email: email }\n      results.push(formatted)\n    } else {\n      continue\n    }\n  }\n  const output = results\n  return output\n}\n\nexport function isValid(record) {\n  if (record.name && record.email) {\n    return true\n  }\n  return false\n}\n\nexport function wrapProcess(records) {\n  return processUserRecords(records)\n}\n\nexport function safeProcess(records) {\n  try {\n    return processUserRecords(records)\n  } catch (e) {\n    throw e\n  }\n}\n',
        "verbose.test.js": "import {isValid} from './verbose.js'\nit('x',()=>{expect(isValid({})).toBe(false)})\n",
    }, "verbose.js", "verbosity"),

    ("high cyclomatic complexity (py)", {
        "__init__.py": "from . import c\n",
        "c.py": "def big(x):\n" + "".join(
            "    if x == %d:\n        return %d\n" % (i, i) for i in range(20)) +
            "    return -1\n",
    }, "c.py", "complexity"),
]

CLEAN = [
    ("acyclic, wired, asserted", {
        "index.js": "import {add} from './add.js'\nexport const boot = () => add(1,2)\n",
        "add.js": "export const add = (a,b) => a + b\n",
        "add.test.js": "import {add} from './add.js'\nit('adds', () => { expect(add(1,2)).toBe(3) })\n",
    }, "add.js"),

    ("fetch WITH abort signal", {
        "index.js": "import './net.js'\n",
        "net.js": ("export async function get(u){\n"
                   "  const r = await fetch(u, { signal: AbortSignal.timeout(5000) })\n"
                   "  return r.json() }\n"),
    }, "net.js"),

    ("comments describing network calls are not network calls", {
        "index.js": "import './net.js'\n",
        "net.js": (
            "// Only safe on a FULL segment fetch (no Range) — a Range fetch (seek)\n"
            "/* the byte path does its own fetch (capped) further down */\n"
            "export async function get(u){\n"
            "  const r = await fetch(u, { signal: AbortSignal.timeout(5000) })\n"
            "  return r.json() }\n"),
    }, "net.js"),

    ("a URL's // is not a line comment", {
        "index.js": "import './net2.js'\n",
        "net2.js": (
            "export async function get(){\n"
            "  const u = 'http://example.test/a'; const r = await fetch(u, { signal: AbortSignal.timeout(5000) })\n"
            "  return r.json() }\n"),
    }, "net2.js"),

    ("framework route is an entrypoint, not an orphan", {
        "index.js": "export const boot = () => 1\n",
        "app/api/thing/route.ts": "export async function GET(){ return new Response('ok') }\n",
    }, "app/api/thing/route.ts"),

    ("coalescing that shares buffered bytes, not the Response", {
        "index.js": "import './collapse2.js'\n",
        "collapse2.js": (
            "const inflight = new Map()\n"
            "export async function get(u){\n"
            "  let p = inflight.get(u)\n"
            "  if (!p) {\n"
            "    p = Promise.resolve().then(() => fetch(u, { signal: AbortSignal.timeout(5000) }))\n"
            "      .then(async (r) => Buffer.from(await r.arrayBuffer()))\n"
            "    inflight.set(u, p)\n"
            "  }\n"
            "  return p\n"
            "}\n"),
    }, "collapse2.js"),

    ("catch that re-throws", {
        "index.js": "import './h.js'\n",
        "h.js": "export function h(){ try { risky() } catch (e) { throw new Error('ctx: '+e.message) } }\n",
    }, "h.js"),

    ("migration with rollback", {
        "index.js": "export const boot = () => 1\n",
        "migrations/001_add.js": ("export function up(db){ db.addColumn('users','email') }\n"
                                  "export function down(db){ db.dropColumn('users','email') }\n"),
    }, "migrations/001_add.js"),

    ("map lookup, not linear scan", {
        "index.js": "import './s.js'\n",
        "s.js": ("export function join(as, bs){ const ix = new Map(bs.map(b => [b.id, b]))\n"
                 "  const out=[]\n  for (const a of as) { out.push(ix.get(a.id)) }\n"
                 "  return out }\n"),
    }, "s.js"),


    ("layers pointing the right way", {
        "index.js": "import './api/route.js'\n",
        "api/route.js": "import {rule} from '../domain/rule.js'\nexport const h = () => rule()\n",
        "domain/rule.js": "export const rule = () => 1\n",
        "rule.test.js": "import {rule} from './domain/rule.js'\nit('x',()=>{expect(rule()).toBe(1)})\n",
    }, "api/route.js"),

    ("promise chain with catch", {
        "index.js": "import './p.js'\n",
        "p.js": ("export function go(){ return fetch('/x',{signal:AbortSignal.timeout(1)})"
                 ".then(r=>r.json()).catch(e=>{ throw e }) }\n"),
        "p.test.js": "import {go} from './p.js'\nit('x',()=>{expect(go).toBeTruthy()})\n",
    }, "p.js"),

    ("writes inside a transaction", {
        "index.js": "import './w.js'\n",
        "w.js": ("export async function move(a,b){ return db.transaction(async t => {\n"
                 "  await t.update({id:a})\n  await t.insert({id:b})\n }) }\n"),
        "w.test.js": "import {move} from './w.js'\nit('x',()=>{expect(move).toBeTruthy()})\n",
    }, "w.js"),

    ("mutating route WITH authz", {
        "index.js": "import './routes.js'\n",
        "routes.js": ("export function wire(app){ app.post('/users/:id', requireAuth, "
                      "(req,res) => { res.end() }) }\n"),
        "routes.test.js": "import {wire} from './routes.js'\nit('x',()=>{expect(wire).toBeTruthy()})\n",
    }, "routes.js"),


    ("narrow except:pass WITH a real reason", {
        "__init__.py": "from . import n\n",
        "n.py": ("def h(x):\n    try:\n        return int(x)\n    except ValueError:\n"
                 "        # a malformed entry is skipped, not fatal to the whole parse\n"
                 "        pass\n"),
        "test_n.py": "from .n import h\n\ndef test_h():\n    assert h('a') is None\n",
    }, "n.py"),

    ("js catch with a real reason", {
        "index.js": "import './ok.js'\n",
        "ok.js": ("export function h(){ try { risky() } catch (e) {\n"
                  "  /* the file can vanish between walk and stat; treat as absent */\n} }\n"),
        "ok.test.js": "import {h} from './ok.js'\nit('x',()=>{expect(h).toBeTruthy()})\n",
    }, "ok.js"),

    ("retry on POST WITH a stated safety reason", {
        "index.js": "import './r2.js'\n",
        "r2.js": ("// A completion is safe to re-issue: it does not mutate anything, so a\n"
                  "// retry costs tokens and nothing else.\n"
                  "export async function send(p){ let retries = 3\n"
                  "  while (retries--) { await fetch('/v1/chat', {method:'POST', body:p, "
                  "signal: AbortSignal.timeout(5000)}) } }\n"),
        "r2.test.js": "import {send} from './r2.js'\nit('x',()=>{expect(send).toBeTruthy()})\n",
    }, "r2.js"),

    ("comment that explains WHY, mentioning a gate", {
        "index.js": "import './e.js'\n",
        "e.js": ("// The arch gate flags this fan-out; it is correct here because this is\n"
                 "// the composition root, which exists precisely to know about everything.\n"
                 "export const compose = () => 1\n"),
        "e.test.js": "import {compose} from './e.js'\nit('x',()=>{expect(compose()).toBe(1)})\n",
    }, "e.js"),

    ("tight code stays under the threshold", {
        "index.js": "import './tight.js'\n",
        "tight.js": "export function processUserRecords(records) {\n  return records\n    .filter((r) => r.active)\n    .map(({ name, email }) => ({ name, email }))\n}\n\nexport const isValid = (r) => Boolean(r.name && r.email)\n\nexport function summarize(records) {\n  const byDomain = new Map()\n  for (const { email } of records) {\n    const domain = email.slice(email.indexOf('@') + 1)\n    byDomain.set(domain, (byDomain.get(domain) ?? 0) + 1)\n  }\n  return [...byDomain].sort((a, b) => b[1] - a[1])\n}\n\nexport function firstMatch(records, predicate) {\n  for (const r of records) if (predicate(r)) return r\n  return null\n}\n\nexport function groupBy(records, keyOf) {\n  const out = new Map()\n  for (const r of records) {\n    const k = keyOf(r)\n    const bucket = out.get(k)\n    if (bucket) bucket.push(r)\n    else out.set(k, [r])\n  }\n  return out\n}\n",
        "tight.test.js": "import {isValid} from './tight.js'\nit('x',()=>{expect(isValid({})).toBe(false)})\n",
    }, "tight.js"),

    ("python test that asserts", {
        "__init__.py": "from . import m\n",
        "m.py": "def f():\n    return 1\n",
        "test_m.py": "from .m import f\n\ndef test_works():\n    assert f() == 1\n",
    }, "test_m.py"),
]


def build(files):
    d = tempfile.mkdtemp(prefix="archscan-corpus-")
    for rel, src in files.items():
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(src)
    return d


def run(scanner):
    """-> list of failure strings."""
    failures = []

    for name, files, target, expect in DEFECTS:
        d = build(files)
        try:
            found = scanner(d, [os.path.join(d, target)])
            kinds = {f["kind"] for f in found}
            if expect not in kinds:
                failures.append("MISSED  %-32s expected %-20s got %s"
                                % (name, expect, sorted(kinds) or "nothing"))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    for name, files, target in CLEAN:
        d = build(files)
        try:
            found = scanner(d, [os.path.join(d, target)])
            high = [f for f in found if f["severity"] == "high"]
            if high:
                failures.append("FALSE+  %-32s flagged %s"
                                % (name, [f["kind"] for f in high]))
        finally:
            shutil.rmtree(d, ignore_errors=True)

    return failures


def main(argv):
    self_test = "--self-test" in argv

    if self_test:
        # A scanner that finds nothing must make this suite fail.
        failures = run(lambda root, targets: [])
        expected = len(DEFECTS)
        if len(failures) == expected:
            print("  SELF-TEST PASSED — a scanner that reports nothing misses all %d "
                  "planted defects." % expected)
            return 0
        print("  SELF-TEST FAILED — an empty scanner only failed %d of %d defect cases."
              % (len(failures), expected))
        print("  This suite does not actually verify the scanner.")
        return 1

    failures = run(archscan.scan)
    total = len(DEFECTS) + len(CLEAN)
    for name, _, _, expect in DEFECTS:
        if not any(name in f for f in failures):
            print("  ok    detects %-34s (%s)" % (name, expect))
    for name, _, _ in CLEAN:
        if not any(name in f for f in failures):
            print("  ok    passes  %s" % name)
    for f in failures:
        print("  " + f)
    print("\n  %d/%d passed" % (total - len(failures), total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
