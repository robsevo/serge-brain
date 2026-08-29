#!/usr/bin/env bash
# Serge download gate — PreToolUse on Bash. Judges the SOURCE of a download
# before it happens. $0, no LLM, no network.
#
# WHY THIS IS THE PRE-HALF AND NOT THE WHOLE JOB:
# before the fetch there are no bytes, so nothing here can tell you whether a
# file is malicious — only whether the way it is being obtained is a shape that
# gets people owned. The bytes are scanned afterwards by download-scan.sh
# (PostToolUse), which is where an actual AV engine runs. Neither half proves a
# file is clean; that is not a thing any scanner can prove.
#
# NOT DUPLICATED HERE: `curl … | bash` is already caught by the ENGINE's
# permission heuristics (src/permissions.mjs, DANGEROUS → 'pipe-to-shell'),
# which asks before running it. Re-blocking it here would be two prompts for
# one command.
#
# WHAT IT BLOCKS (executable payload AND a source that cannot be trusted):
#   1. an executable/installer (.sh .exe .msi .deb .AppImage .jar …), fetched
#   2. over plain http://  → tamperable in transit, so the bytes you scan are
#      not necessarily the bytes the publisher signed, or
#      from a raw IP        → no name, no TLS identity, nothing to reputation, or
#      from an anonymous file host / URL shortener → destination is unaccountable.
#
# A plain `curl https://api.example.com/thing.json` is not this hook's business
# and stays silent. So does an https download of an executable from a named
# host — that is normal, and the post-scan covers it.
#
# BLOCK ONCE per (session, url): re-issuing goes through, so a deliberate fetch
# costs one turn and never a dead end. Same shape as vague-delete-gate.sh.
#
# Fails OPEN on any parse error or unreadable input.
# Off-switch: SERGE_DOWNLOAD_GATE_DISABLE=1
set -uo pipefail

[ "${SERGE_DOWNLOAD_GATE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, hashlib, shlex

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "PreToolUse":
    sys.exit(0)
if str(d.get("tool_name") or "") != "Bash":
    sys.exit(0)

cmd = str((d.get("tool_input") or {}).get("command") or "")
if not cmd.strip():
    sys.exit(0)

# ── is this a fetch at all? ───────────────────────────────────────────────────
if not re.search(r"(?:^|[;&|(]|\s)(?:curl|wget|aria2c|http|httpie)\b", cmd, re.I):
    sys.exit(0)

URL = re.compile(r"https?://[^\s'\"`|;&>)]+", re.I)
urls = URL.findall(cmd)
if not urls:
    sys.exit(0)

# Payloads that RUN. A .json or .tar.gz of source is not what this gate is for;
# these are the things whose whole purpose is to execute on your machine.
EXEC_EXT = re.compile(
    r"\.(?:sh|bash|zsh|fish|ps1|bat|cmd|exe|msi|scr|com|vbs|vbe|js|jse|wsf|hta|"
    r"deb|rpm|pkg|dmg|apk|jar|appimage|bin|run|elf|so|dylib|dll)(?:$|[?#])",
    re.I,
)

# Hosts that exist to make an upload untraceable, plus shorteners (which hide
# the destination entirely, so nothing about it can be judged).
ANON_HOST = re.compile(
    r"(?:^|\.)(?:anonfiles\.com|bayfiles\.com|mediafire\.com|mega\.nz|gofile\.io|"
    r"file\.io|transfer\.sh|temp\.sh|0x0\.st|catbox\.moe|litterbox\.catbox\.moe|"
    r"pixeldrain\.com|send\.now|dropmefiles\.com|ufile\.io|"
    r"bit\.ly|tinyurl\.com|goo\.gl|t\.co|is\.gd|ow\.ly|buff\.ly|rb\.gy|shorturl\.at|cutt\.ly)$",
    re.I,
)

RAW_IP = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$|^\[?[0-9a-f:]+\]?$", re.I)

def host_of(u):
    m = re.match(r"https?://(?:[^/@]*@)?([^/:?#]+)", u, re.I)
    return (m.group(1) if m else "").lower().strip("[]")

findings = []
for u in urls:
    u = u.rstrip(".,)")
    if not EXEC_EXT.search(u):
        continue                      # not an executable payload → not our business
    h = host_of(u)
    why = None
    if u.lower().startswith("http://"):
        why = "plain http — the bytes can be swapped in transit by anyone on the path"
    elif RAW_IP.match(h):
        why = f"a raw IP address ({h}) — no domain, no TLS identity, nothing to check it against"
    elif ANON_HOST.search(h):
        why = f"{h} — an anonymous file host or URL shortener, with no accountable publisher"
    if why:
        findings.append((u, why))

if not findings:
    sys.exit(0)

# ── block once per (session, url set) ────────────────────────────────────────
sid = str(d.get("session_id") or "nosid")
key = "|".join(sorted(u for u, _ in findings))
mark = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-dlgate-%s-%s" % (
        hashlib.sha1(sid.encode("utf-8", "ignore")).hexdigest()[:12],
        hashlib.sha1(key.encode("utf-8", "ignore")).hexdigest()[:16],
    ),
)
if os.path.exists(mark):
    sys.exit(0)                       # already said it once; insistence wins
try:
    open(mark, "w").close()
except Exception:
    pass

lines = "\n".join(f"  - {u}\n    {why}" for u, why in findings[:4])
reason = (
    "This downloads something that EXECUTES, from a source that cannot be vouched for:\n\n"
    + lines
    + "\n\nA scanner runs on the bytes after they land, but a scanner only recognises "
    "malware it already has a signature for — it does not certify a file as safe, and it "
    "is not a substitute for knowing where the file came from.\n\n"
    "Before re-issuing, do whichever applies:\n"
    "  - prefer the distro/package manager (pacman, npm, pip) over a loose binary — "
    "those paths are signed and versioned;\n"
    "  - switch http:// to https:// if the host supports it;\n"
    "  - verify a published checksum or GPG signature AFTER downloading and BEFORE running it;\n"
    "  - if the user explicitly asked for this exact URL, say so and re-issue the same "
    "command — it will go through."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}))
PY
