#!/usr/bin/env bash
# Serge download scanner — PostToolUse on Bash. Scans files that were just
# downloaded to disk. Local CPU, zero token cost, nothing leaves the machine.
#
# WHY POST AND NOT PRE: a PreToolUse hook runs before the fetch, when there are
# no bytes to look at. This is the only point in the turn where the actual file
# exists and can be scanned. A file sitting on disk is inert — the danger is
# EXECUTING it — so catching it here, before serge runs or installs it, is in
# time.
#
# WHAT IT PROVES: that ClamAV's signature database does not recognise the file.
# That is not the same as "clean". Signature AV misses anything novel, packed or
# targeted. It is a real floor, not a guarantee, and the block text says so
# rather than letting the model conclude the file was certified.
#
# NO AV INSTALLED → the hook does NOT pretend. It says once per session that no
# engine is present, and falls back to a SHAPE check only: a file whose magic
# bytes disagree with its name (an "invoice.pdf" that is really an ELF binary,
# a ".jpg" that starts with #!/bin/sh) is the classic dropper trick and `file`
# catches it for free. That check is labelled as what it is.
#
# INSTALL THE REAL THING:  sudo pacman -S clamav && sudo freshclam
#
# Toggles:
#   SERGE_DOWNLOAD_SCAN_DISABLE=1   turn the hook off entirely
#   SERGE_DOWNLOAD_SCAN_MAXMB=N     skip files larger than N MB (default 512)
set -uo pipefail

[ "${SERGE_DOWNLOAD_SCAN_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0             # don't scan inside eval child runs
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, shlex, shutil, subprocess, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "PostToolUse":
    sys.exit(0)
if str(d.get("tool_name") or "") != "Bash":
    sys.exit(0)

cmd = str((d.get("tool_input") or {}).get("command") or "")
if not cmd.strip() or not re.search(r"(?:^|[;&|(]|\s)(?:curl|wget|aria2c)\b", cmd, re.I):
    sys.exit(0)

cwd = d.get("cwd") or os.getcwd()

# ── which files did this command write? ──────────────────────────────────────
# Only EXPLICITLY identifiable download targets are scanned. Guessing from
# "files modified recently" would sweep in build output and unrelated writes,
# and a scanner that cries wolf on your own dist/ gets turned off within a day.
def targets(command):
    try:
        toks = shlex.split(command, comments=False)
    except ValueError:
        return []

    out, tool = [], None
    i = 0
    while i < len(toks):
        t = toks[i]
        base = os.path.basename(t).lower()
        if base in ("curl", "wget", "aria2c"):
            tool = base
            i += 1
            continue
        if tool is None:
            i += 1
            continue
        if t in (";", "&&", "||", "|"):
            tool = None
            i += 1
            continue

        nxt = toks[i + 1] if i + 1 < len(toks) else None

        # explicit output path: -o / --output (curl), -O / --output-document (wget)
        if t in ("-o", "--output") and tool in ("curl", "aria2c") and nxt:
            if nxt != "-":
                out.append(nxt)
            i += 2
            continue
        if t in ("-O", "--output-document") and tool == "wget" and nxt:
            if nxt not in ("-", "/dev/stdout"):
                out.append(nxt)
            i += 2
            continue
        # curl bundles short flags: -sSLo out.bin  → the 'o' must be last
        if tool == "curl" and re.match(r"^-[a-zA-Z]+$", t) and t[-1] == "o" and nxt:
            if nxt != "-":
                out.append(nxt)
            i += 2
            continue
        # curl -O / --remote-name  → server-chosen name in cwd
        if tool == "curl" and (t in ("-O", "--remote-name")
                               or (re.match(r"^-[a-zA-Z]+$", t) and "O" in t)):
            u = next((x for x in toks[i:] if re.match(r"https?://", x, re.I)), None)
            if u:
                out.append(os.path.basename(u.split("?")[0].split("#")[0]))
            i += 1
            continue
        # bare `wget URL` / `aria2c URL` → basename in cwd
        if tool in ("wget", "aria2c") and re.match(r"https?://", t, re.I):
            name = os.path.basename(t.split("?")[0].split("#")[0])
            if name:
                out.append(name)
            i += 1
            continue
        i += 1
    return out

paths = []
for p in targets(cmd):
    ap = p if os.path.isabs(p) else os.path.join(cwd, p)
    try:
        if os.path.isfile(ap) and os.path.getsize(ap) > 0 and ap not in paths:
            paths.append(ap)
    except OSError:
        pass

if not paths:
    sys.exit(0)

maxmb = int(os.environ.get("SERGE_DOWNLOAD_SCAN_MAXMB") or 512)
paths = [p for p in paths if os.path.getsize(p) <= maxmb * 1024 * 1024]
if not paths:
    sys.exit(0)

def block(text):
    sys.stderr.write(text + "\n")
    sys.exit(2)          # PostToolUse: exit 2 → blocked, stderr goes to the model

# ── 1. real AV, if the machine has one ───────────────────────────────────────
scanner = None
if shutil.which("clamdscan"):
    scanner = ["clamdscan", "--fdpass", "--no-summary"]
elif shutil.which("clamscan"):
    scanner = ["clamscan", "--no-summary", "--infected",
               "--max-filesize=%dM" % maxmb, "--max-scansize=%dM" % (maxmb * 2)]

if scanner:
    try:
        r = subprocess.run(scanner + paths, capture_output=True, text=True, timeout=180)
    except Exception:
        sys.exit(0)                      # scanner broke → proved nothing, stay out of the way
    if r.returncode == 1:                # clamav: 1 == virus found
        hits = "\n".join("  " + l for l in (r.stdout or "").splitlines() if "FOUND" in l)
        block(
            "MALWARE DETECTED in a file this command just downloaded. ClamAV reports:\n\n"
            + (hits or "  (see scanner output)")
            + "\n\nDo NOT run, install, extract, source or open it. Delete it now:\n"
            + "\n".join("  rm -f -- %s" % shlex.quote(p) for p in paths)
            + "\n\nThen tell the user what was downloaded, from which URL, and what the "
              "detection was called. Do not retry the same URL."
        )
    # returncode 2 == scanner error (missing signature DB, permissions) → fail open, silently
    sys.exit(0)

# ── 2. no AV: say so once, and do a SHAPE check only ─────────────────────────
EXEC_MAGIC = [
    (b"\x7fELF",     "an ELF executable/shared object (Linux binary)"),
    (b"MZ",          "a DOS/PE executable (Windows .exe or .dll)"),
    (b"\xca\xfe\xba\xbe", "a Mach-O fat binary (macOS)"),
    (b"\xcf\xfa\xed\xfe", "a Mach-O executable (macOS)"),
    (b"\xfe\xed\xfa\xce", "a Mach-O executable (macOS)"),
    (b"#!",          "a script with a shebang (it is meant to be executed)"),
]
# Names that promise inert data. A binary wearing one of these is the dropper shape.
DATA_EXT = re.compile(
    r"\.(?:pdf|jpe?g|png|gif|webp|bmp|svg|txt|md|csv|tsv|json|ya?ml|xml|toml|ini|"
    r"log|doc|docx|xls|xlsx|ppt|pptx|rtf|html?)$", re.I)

mismatches = []
for p in paths:
    if not DATA_EXT.search(p):
        continue
    try:
        with open(p, "rb") as fh:
            head = fh.read(8)
    except OSError:
        continue
    for magic, desc in EXEC_MAGIC:
        if head.startswith(magic):
            mismatches.append((p, desc))
            break

if mismatches:
    block(
        "A downloaded file's CONTENTS do not match its name — the standard disguise for a dropper:\n\n"
        + "\n".join("  %s\n    is actually %s" % (p, desc) for p, desc in mismatches)
        + "\n\nNo antivirus is installed on this machine, so this is a shape check, not a scan: "
          "it cannot tell you the file is malicious, only that it is lying about what it is. "
          "Treat it as hostile until proven otherwise.\n\n"
          "Do NOT run, source or open it. Delete it, tell the user the URL it came from, and "
          "stop rather than working around this."
    )

# Clean shape check, but there is no AV — say it ONCE per session. Staying silent
# would let the model (and the user) believe downloads are being scanned when
# nothing is scanning them, which is worse than no hook at all.
sid = str(d.get("session_id") or "nosid")
mark = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-dlscan-noav-%s" % hashlib.sha1(sid.encode("utf-8", "ignore")).hexdigest()[:12],
)
if not os.path.exists(mark):
    try:
        open(mark, "w").close()
    except Exception:
        pass
    sys.stderr.write(
        "NOTE — downloads are NOT being virus-scanned: no ClamAV on this machine. "
        "The only check that ran was that the file is not disguised as another type. "
        "Tell the user once that `sudo pacman -S clamav && sudo freshclam` enables real "
        "scanning, then carry on — this is a notice, not a failure.\n"
    )
    sys.exit(0)          # exit 0: a notice must not block the turn

sys.exit(0)
PY
