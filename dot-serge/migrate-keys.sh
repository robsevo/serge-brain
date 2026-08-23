#!/usr/bin/env bash
#
# migrate-keys.sh — collect existing keys into the single keys.env file.
#
# keys.env is what a NEW install fills in. An install that predates it has its
# keys spread across router.env and serge.env, so the single-file experience
# simply is not there — which is how it stayed missing on a rig that had the
# template sitting next to it.
#
# Reads router.env and serge.env, writes any key it finds into keys.env at the
# matching slot. Leaves both originals untouched: the launcher sources all three
# (keys.env last), so nothing breaks either way, and a migration that deletes
# your only copy of a key is not a migration.
#
# Safe to run twice — an existing value in keys.env is never overwritten.
#
#   bash migrate-keys.sh              migrate $SERGE_HOME
#   SERGE_HOME=~/.sergio bash migrate-keys.sh
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
TPL="$SH/keys.env.template"
OUT="$SH/keys.env"

[ -f "$TPL" ] || { echo "no keys.env.template in $SH — is this a Serge config dir?" >&2; exit 1; }

python3 - "$SH" "$TPL" "$OUT" <<'PY'
import os, re, sys, stat

sh, tpl, out = sys.argv[1], sys.argv[2], sys.argv[3]

def read_env(path):
    """KEY=value pairs from a shell env file. Values are never printed."""
    vals = {}
    try:
        for line in open(path, encoding='utf-8', errors='ignore'):
            m = re.match(r'^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)$', line)
            if not m:
                continue
            v = m.group(2).strip().strip('"').strip("'")
            if v:
                vals[m.group(1)] = v
    except OSError:
        pass
    return vals

# serge.env first, router.env second: router.env is the one that holds provider
# keys, so it wins on the rare name that appears in both.
existing = {}
for f in ('serge.env', 'router.env'):
    existing.update(read_env(os.path.join(sh, f)))

# Anything already in keys.env stays. Re-running must not clobber a value the
# user edited by hand since the last run.
already = read_env(out) if os.path.exists(out) else {}

body = open(out if os.path.exists(out) else tpl, encoding='utf-8').read()

filled, skipped = [], []
def fill(m):
    name, cur = m.group(1), m.group(2).strip()
    if cur:
        return m.group(0)                      # already set — leave it
    if name in existing:
        filled.append(name)
        return f'{name}={existing[name]}'
    return m.group(0)

body = re.sub(r'^([A-Z0-9_]+)=(.*)$', fill, body, flags=re.M)

# A key that exists but has no slot in the template would be silently dropped,
# so it is appended rather than lost.
slots = set(re.findall(r'^([A-Z0-9_]+)=', body, flags=re.M))
extra = [k for k in existing
         if k not in slots and re.search(r'(API_KEY|TOKEN|SECRET)', k)]
if extra:
    body = body.rstrip('\n') + '\n\n# Carried over from router.env / serge.env — no slot in the template.\n'
    for k in sorted(extra):
        body += f'{k}={existing[k]}\n'
        filled.append(k)

open(out, 'w', encoding='utf-8').write(body)
os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)     # 600

print(f"  wrote {out}  (mode 600)")
if filled:
    print(f"  carried over {len(filled)} key(s): {', '.join(sorted(set(filled)))}")
else:
    print("  nothing to carry over — keys.env was already populated")
if already:
    print(f"  left {len(already)} existing value(s) untouched")
print("  router.env and serge.env are unchanged; the launcher reads all three.")
PY
