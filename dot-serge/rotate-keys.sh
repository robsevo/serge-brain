#!/usr/bin/env bash
#
# rotate-keys.sh — give a provider a second (or third) account.
#
# litellm already load-balances across every deployment that shares a
# model_name; `free-qwen` runs four of them today. So a spare account is not new
# routing code, it is a duplicate deployment entry pointing at a different key —
# and when one account hits its quota, litellm's own retry moves to the other.
#
# Put a second key in ~/.serge/keys.env as the same name with _2 (or _3):
#
#   GEMINI_API_KEY=AI...first
#   GEMINI_API_KEY_2=AI...second
#
# then run this. It rewrites the generated block in litellm.yaml and nothing
# else; the hand-written seats above it are never touched.
#
#   bash rotate-keys.sh            apply
#   bash rotate-keys.sh --dry-run  show what would change
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
CFG="$SH/litellm.yaml"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -f "$CFG" ] || { echo "no litellm.yaml at $CFG" >&2; exit 1; }

for f in "$SH/router.env" "$SH/serge.env" "$SH/keys.env"; do
  [ -f "$f" ] && { set -a; . "$f" 2>/dev/null; set +a; }
done

BEGIN="# >>> rotate-keys.sh: generated spare-account deployments >>>"
END="# <<< rotate-keys.sh <<<"

python3 - "$CFG" "$BEGIN" "$END" "$DRY" <<'PY'
import re, sys, os, io

cfg_path, begin, end, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
text = io.open(cfg_path, encoding="utf-8").read()

# Everything this script has written before is replaced wholesale. Editing in
# place would compound: run it twice and you would have four copies of a seat.
body = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.S)

# Only the model_list is scanned. A deployment is a `- model_name:` block and
# everything indented under it until the next one.
m = re.search(r"^model_list:\s*$", body, re.M)
if not m:
    print("  litellm.yaml has no model_list — nothing to do")
    raise SystemExit(0)

start = m.end()
nxt = re.search(r"^[a-z_]+:\s*$", body[start:], re.M)
model_list = body[start:start + nxt.start()] if nxt else body[start:]

blocks = re.split(r"(?m)^(?=\s*- model_name:)", model_list)
generated, seen = [], []

for b in blocks:
    if not b.strip().startswith("- model_name:"):
        continue
    keys = re.findall(r"os\.environ/([A-Z0-9_]+)", b)
    if not keys:
        continue
    primary = keys[0]
    # Already an alternate — do not rotate a rotation.
    if re.search(r"_\d+$", primary):
        continue
    for n in (2, 3, 4):
        alt = f"{primary}_{n}"
        if not os.environ.get(alt):
            continue
        name = re.search(r"- model_name:\s*(\S+)", b).group(1)
        # The alternate is the SAME deployment with a different key, so the
        # model, its params and its limits all carry over unchanged. Only the
        # key and the id differ.
        # Comments are dropped. Splitting on `- model_name:` puts a block's
        # TRAILING comments — which describe the NEXT seat — inside it, so
        # copying them verbatim files a paragraph about one seat under another.
        block = "\n".join(l for l in b.split("\n") if not l.strip().startswith("#")).rstrip("\n")
        block = block.replace(f"os.environ/{primary}", f"os.environ/{alt}")
        block = re.sub(r"(- model_name:\s*)(\S+)", r"\1\2", block)
        # A distinct model_info id keeps litellm's per-deployment accounting
        # separate; without it the two accounts share one rate-limit budget,
        # which is the entire thing this exists to avoid.
        if "model_info:" in block:
            block = re.sub(r"(model_info:\s*\n)", rf"\1      id: {name}-alt{n}\n", block, count=1)
        else:
            block = block + f"\n    model_info:\n      id: {name}-alt{n}"
        generated.append(block + "\n")
        seen.append((name, alt))

if not generated:
    print("  no *_API_KEY_2 (or _3) set — nothing to rotate")
    print("  add one to ~/.serge/keys.env, e.g.  GEMINI_API_KEY_2=...")
    raise SystemExit(0)

for name, alt in seen:
    print(f"  + {name}  ->  {alt}")

# Appended at the END of model_list so the hand-written seats keep their order
# and their comments.
insert_at = start + (nxt.start() if nxt else len(model_list))
out = body[:insert_at].rstrip("\n") + "\n\n" + begin + "\n" + "".join(generated) + end + "\n" + body[insert_at:]

if dry:
    print(f"\n  --dry-run: {len(generated)} deployment(s) would be added; nothing written")
    raise SystemExit(0)

io.open(cfg_path + ".tmp", "w", encoding="utf-8").write(out)
os.replace(cfg_path + ".tmp", cfg_path)
print(f"\n  wrote {len(generated)} spare deployment(s) to {cfg_path}")
PY

rc=$?
if [ "$rc" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  # A malformed yaml takes the whole router down, so it is checked before the
  # user is told to restart into it.
  if python3 -c "import yaml,sys; yaml.safe_load(open('$CFG'))" 2>/dev/null; then
    echo "  litellm.yaml still parses"
    echo "  restart the router to pick it up:  systemctl --user restart serge-router"
  else
    echo "  WARNING: litellm.yaml no longer parses as yaml — inspect it before restarting" >&2
    exit 1
  fi
fi
exit $rc
