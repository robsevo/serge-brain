#!/usr/bin/env bash
# Serge installer — wires the brain in this repo onto an engine you supply.
#
# Supports: Linux (systemd) · macOS (launchd) · Windows via WSL2 or Git Bash.
#
# What it does, in order:
#   1. Checks prerequisites and stops early if something required is missing.
#   2. Copies dot-serge/ -> ~/.serge  (refuses to clobber; --force backs up first)
#   3. Generates settings.json from the template, substituting REAL absolute
#      paths into every hook command.
#   4. Creates router.env / serge.env from the blank templates at mode 600.
#   5. Installs service units (systemd/launchd). Does NOT enable them.
#   6. Puts `serge` on your PATH.
#
# It never writes a key and never starts a service — it prints the commands.
#
# Usage:
#   ./install.sh --engine /path/to/engine
#   ./install.sh --engine /path/to/engine --force     # back up an existing ~/.serge
#   ./install.sh --engine /path/to/engine --dry-run   # show what would happen
#
#   SERGE_HOME="$HOME/.serge-trial" ./install.sh --engine /path/to/engine
#                                                     # try it WITHOUT touching a
#                                                     # working install — do this
#                                                     # to evaluate a build
#
#   ./install.sh --engine ... --force --replace-live  # replace a RUNNING install.
#                                                     # --force alone will refuse;
#                                                     # see the live-install guard.
#
#   ./install.sh --engine ... --replace-path          # take over the `serge` command
#                                                     # when another install already
#                                                     # owns it; see the PATH guard.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
ENGINE=""
FORCE=0
REPLACE_LIVE=0
REPLACE_PATH=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:?--engine needs a path}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    --replace-live) REPLACE_LIVE=1; shift ;;
    --replace-path) REPLACE_PATH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
    *) echo "install: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

say()  { echo "$@"; }
run()  { if [ "$DRY" = "1" ]; then echo "   [dry-run] $*"; else eval "$@"; fi; }
die()  { echo "install: $*" >&2; exit 1; }

case "$(uname -s)" in
  Linux*)   OS=linux ;;
  Darwin*)  OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=gitbash ;;
  *) OS=unknown ;;
esac
say "== Serge installer (detected: $OS)"

# ------------------------------------------------------------------ engine ---
# The engine is deliberately not in this repo — it is a Claude Code derivative
# and not ours to redistribute. See README §3.
[ -n "$ENGINE" ] || die "--engine is required.
  This repo ships Serge's brain, not the CLI. Point at a Claude Code-compatible
  engine directory:  ./install.sh --engine /path/to/engine
  See README section 3 for why."
[ -d "$ENGINE" ] || die "engine path does not exist: $ENGINE"

# ------------------------------------------------- engine runtime deps -------
# The engine bundle is NOT self-contained. `dist/cli.mjs` externalises ~16
# package roots (@orama, @aws-sdk, @smithy, tslib, …), so a checkout without
# node_modules dies on first launch with:
#   ERR_MODULE_NOT_FOUND: Cannot find package '@orama/orama' imported from
#   .../engine/dist/cli.mjs
# node_modules is git-ignored (correctly — it must not be committed), so a fresh
# clone NEVER has them and nothing here used to say so. Installing them is the
# installer's job.
#
# Then PROVE it: booting the bundle is the only check that the dependency
# closure is actually complete, and it stays true for free when the engine's
# imports change — there is no pattern to keep in step. sync-portable.sh makes
# the same argument about the mirror.
if [ -f "$ENGINE/package.json" ]; then
  if [ ! -d "$ENGINE/node_modules" ]; then
    say "-- Installing engine runtime dependencies (first run only)"
    if command -v bun >/dev/null 2>&1 && [ -f "$ENGINE/bun.lock" ]; then
      run "(cd '$ENGINE' && bun install --production)"
    elif command -v npm >/dev/null 2>&1; then
      run "(cd '$ENGINE' && npm install --omit=dev --no-audit --no-fund)"
    else
      die "the engine needs its dependencies installed and neither bun nor npm is available.
  Install one, then run:  cd '$ENGINE' && npm install --omit=dev"
    fi
  fi
  if [ "$DRY" = "0" ] && [ -f "$ENGINE/dist/cli.mjs" ]; then
    if ENGINE_V=$(cd "$ENGINE" && node dist/cli.mjs --version 2>&1); then
      say "   ok   engine starts — $ENGINE_V"
    else
      die "the engine will not start even after installing dependencies:
$ENGINE_V
  Nothing else here can work until that does. Try: cd '$ENGINE' && npm install --omit=dev"
    fi
  fi
fi

ENGINE="$(cd "$ENGINE" && pwd)"
ENGINE_BIN=""
for cand in "$ENGINE/serge" "$ENGINE/bin/serge" "$ENGINE/claude" "$ENGINE/bin/claude"; do
  [ -x "$cand" ] && { ENGINE_BIN="$cand"; break; }
done
[ -n "$ENGINE_BIN" ] || die "no executable launcher found in $ENGINE
  Looked for: serge, bin/serge, claude, bin/claude"
say "-- Engine launcher: $ENGINE_BIN"

# ----------------------------------------------------------------- prereqs ---
say "-- Checking prerequisites"
missing=0
need() {
  if command -v "$1" >/dev/null 2>&1; then
    say "   ok   $1"
  else
    say "   MISSING  $1 — $2"; missing=1
  fi
}
need node   "Node.js >= 22 (nodejs.org)"
need python3 "python3 (hook helpers)"
need curl   "curl (health checks)"

if command -v node >/dev/null 2>&1; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "${major:-0}" -ge 22 ] || { say "   MISSING  node >= 22 (found $major)"; missing=1; }
fi

if command -v litellm >/dev/null 2>&1; then
  say "   ok   litellm"
else
  say "   MISSING  litellm — uv tool install 'litellm[proxy]'"; missing=1
fi

if [ "$OS" = "macos" ]; then
  # Hooks use GNU timeout/stat/sha256sum. BSD versions take different flags and
  # fail in ways that look like the hook "did nothing".
  if timeout --version >/dev/null 2>&1; then
    say "   ok   GNU coreutils"
  else
    say "   MISSING  GNU coreutils — brew install coreutils, then put gnubin on PATH:"
    say "            export PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\""
    missing=1
  fi

  # Advisory, not fatal. Every shipped script is written to bash 3.2 (macOS's
  # stock /bin/bash, from 2007) and is checked for bash-4-only builtins, so this
  # is a warning rather than a blocker. It is here because a bash-4 construct
  # slipping in later would fail on a Mac with an error that names a builtin
  # rather than the real cause, and nothing else in the install would hint at it.
  if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    say "   note bash ${BASH_VERSION%%(*} — the stock macOS build."
    say "            Supported: the scripts avoid bash 4+ builtins on purpose."
    say "            If you ever see 'mapfile: command not found', that is a bug"
    say "            in Serge, not your system — please report it."
  fi
fi

command -v semgrep >/dev/null 2>&1 && say "   ok   semgrep (optional)" \
  || say "   --   semgrep absent (optional; the security-scan hook no-ops)"

# --dry-run previews; it does not install, so it has no business demanding a
# fully provisioned machine. Making it fatal here meant the shipped CI could
# never exercise the installer at all (a hosted runner has no litellm), and it
# also blocked the obvious "what would this do to my box?" question people ask
# BEFORE installing the dependencies. Real runs still refuse.
if [ "$missing" != "0" ]; then
  if [ "$DRY" = "1" ]; then
    say "   note dry run: continuing despite the missing prerequisite(s) above."
    say "            A real run would stop here until they are installed."
  else
    die "install a missing prerequisite above and re-run."
  fi
fi

# ----------------------------------------------------------------- ~/.serge ---
# LIVE-INSTALL GUARD (added 2026-08-15 after this installer decapitated a working
# box). `--force` was written for the stale-leftover case — a half-finished
# install, an abandoned trial — and it is right for that. But `--force` on a
# LEFTOVER and `--force` on a RUNNING SYSTEM are the same keystroke, and the
# blast radius is not remotely the same:
#
#   What actually happened: --force moved a live ~/.serge aside and installed the
#   sanitized public brain over it. Nothing errored. The keys became blanks, the
#   38 KB constitution became a 5 KB placeholder, and 69 memories vanished. The
#   engine kept running and reported nothing, because CLAUDE.md is only an
#   @-import line — whichever file it names IS the personality, and a placeholder
#   is a perfectly valid file. It took two hours and a stranded router to notice.
#
#   The nastiest part is the router: it had already loaded the real keys into its
#   process environment, so it kept working after the overwrite. The obvious
#   recovery move — restart it — is the one that makes the damage permanent,
#   because systemd re-reads the now-blank EnvironmentFile.
#
# So: detect that this is a LIVE install and make the operator say so explicitly.
# Every signal is local, free, and a fact rather than a guess.
detect_live() {
  [ -d "$SERGE_HOME" ] || return 0
  # The running router is a GLOBAL fact, so it only says something about THIS
  # SERGE_HOME if it is the config this router actually reads. Without that
  # check, installing to a sandbox prefix while your real router runs would be
  # refused — which would train people to reach for --replace-live, exactly the
  # reflex this guard exists to prevent.
  if command -v systemctl >/dev/null 2>&1 &&
     systemctl --user is-active --quiet serge-router 2>/dev/null; then
    envf="$(systemctl --user show serge-router -p EnvironmentFiles --value 2>/dev/null)"
    envf="${envf%% (*}"
    case "$envf" in
      "$SERGE_HOME"/*) echo "  - the model router is RUNNING right now off this exact config ($envf)" ;;
    esac
  fi
  if command -v launchctl >/dev/null 2>&1 &&
     launchctl list 2>/dev/null | grep -q "com\.serge\.router" &&
     [ "$SERGE_HOME" = "$HOME/.serge" ]; then
    echo "  - the model router is RUNNING right now (launchd: com.serge.router)"
  fi
  for e in keys.env router.env serge.env; do
    [ -f "$SERGE_HOME/$e" ] || continue
    if awk -F= '
        /^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(API_KEY|TOKEN|SECRET)[[:space:]]*=/ {
          v = $2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", v)
          if (v != "" && v !~ /^(sk-)?(dummy|changeme|your-|xxx|placeholder)/) { found = 1 }
        }
        END { exit(found ? 0 : 1) }' "$SERGE_HOME/$e" 2>/dev/null; then
      echo "  - $e holds REAL provider credentials"
    fi
  done
  n=$(find "$SERGE_HOME/memory" -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l)
  [ "${n:-0}" -gt 0 ] && echo "  - $n memory file(s) this install accumulated"
  for d in sessions plans tasks seat-notes; do
    n=$(find "$SERGE_HOME/$d" -type f 2>/dev/null | wc -l)
    [ "${n:-0}" -gt 0 ] && echo "  - $d/ holds $n file(s) of working history"
  done
  return 0
}

if [ -e "$SERGE_HOME" ]; then
  LIVE="$(detect_live)"
  if [ "$FORCE" != "1" ]; then
    die "$SERGE_HOME already exists.
  Re-run with --force to back it up and continue, or move it aside yourself.
  Refusing to merge: a half-overwritten config is worse than either state."
  fi
  if [ -n "$LIVE" ] && [ "$REPLACE_LIVE" != "1" ]; then
    die "$SERGE_HOME is a LIVE install, not a leftover:
$LIVE
  --force would move all of that aside and install a blank-keyed brain over it.
  Nothing would error; you would find out later, from a stranded router.

  To try this build WITHOUT touching your working install (what you almost
  certainly want), point SERGE_HOME somewhere else:

      SERGE_HOME=\"\$HOME/.serge-trial\" $0 --engine '$ENGINE'

  If you really do mean to replace the live install, say so explicitly:

      $0 --engine '$ENGINE' --force --replace-live

  Read that flag as: 'yes, replace the system I am currently using.'"
  fi

  BAK="$SERGE_HOME.bak-$(date +%Y%m%d-%H%M%S)"
  say "-- Existing $SERGE_HOME -> $BAK"
  run "mv '$SERGE_HOME' '$BAK'"
  if [ -n "$LIVE" ]; then
    say ""
    say "   !! You just displaced a LIVE install. Two things follow from that:"
    say "      1. Your keys are in $BAK — the new router.env is blank."
    say "      2. A router that is still running holds the OLD keys in memory and"
    say "         will keep working until it restarts. Restarting it BEFORE you"
    say "         restore the keys is what makes the outage permanent."
    say "      Undo:  rm -rf '$SERGE_HOME' && mv '$BAK' '$SERGE_HOME'"
    say ""
  fi
fi

say "-- Installing brain -> $SERGE_HOME"
run "mkdir -p '$SERGE_HOME'"
run "cp -a '$HERE/dot-serge/.' '$SERGE_HOME/'"

# ------------------------------------------------------- settings.json -------
# The template carries __SERGE_HOME__ placeholders instead of absolute paths, so
# the repo stays machine-independent. Substitute once, here, where we can check
# the result — rather than trusting $HOME to expand identically in every shell
# the engine might use to run a hook.
if [ -f "$SERGE_HOME/settings.json.template" ]; then
  say "-- Generating settings.json (resolving hook paths)"
  if [ "$DRY" = "0" ]; then
    sed -e "s|__SERGE_HOME__|$SERGE_HOME|g" -e "s|__HOME__|$HOME|g" \
      "$SERGE_HOME/settings.json.template" > "$SERGE_HOME/settings.json"
    rm -f "$SERGE_HOME/settings.json.template"
    python3 -c "import json;json.load(open('$SERGE_HOME/settings.json'))" \
      || die "generated settings.json is not valid JSON"
    left=$(grep -c "__SERGE_HOME__\|__HOME__" "$SERGE_HOME/settings.json" || true)
    [ "$left" = "0" ] || die "placeholders survived in settings.json"
    say "   ok — no placeholders left, JSON valid"
  fi
fi

# Any shipped script that referenced $SERGE_HOME resolves at runtime via the
# launcher's own export, so nothing to rewrite there.

# ------------------------------------------------------------ credentials ----
say "-- Creating blank credential files (mode 600)"
for e in keys.env router.env serge.env; do
  if [ -f "$SERGE_HOME/$e.template" ] && [ ! -f "$SERGE_HOME/$e" ]; then
    run "cp '$SERGE_HOME/$e.template' '$SERGE_HOME/$e'"
    run "chmod 600 '$SERGE_HOME/$e'"
  fi
done

# ---------------------------------------------------------- service layer ----
case "$OS" in
  linux)
    SYS_DIR="$HOME/.config/systemd/user"
    if [ -d "$HERE/systemd" ]; then
      say "-- Installing systemd --user units -> $SYS_DIR"
      run "mkdir -p '$SYS_DIR'"
      run "cp -p '$HERE/systemd/'* '$SYS_DIR/' 2>/dev/null || true"
      if command -v systemctl >/dev/null 2>&1; then
        run "systemctl --user daemon-reload || true"
      else
        say "   systemctl unavailable — on WSL enable systemd first:"
        say "     printf '[boot]\\nsystemd=true\\n' | sudo tee /etc/wsl.conf && wsl --shutdown"
      fi
    fi
    ;;
  macos)
    LA_DIR="$HOME/Library/LaunchAgents"
    if [ -d "$HERE/launchd" ]; then
      say "-- Installing launchd agents -> $LA_DIR"
      run "mkdir -p '$LA_DIR'"
      run "cp -p '$HERE/launchd/'com.serge.*.plist '$LA_DIR/' 2>/dev/null || true"
    fi
    ;;
  gitbash)
    say "-- Git Bash: no service layer (the launcher starts the router itself)"
    ;;
esac

# --------------------------------------------------------------- launcher ----
# PATH GUARD (added 2026-08-19, the sequel to the live-install guard above).
# ~/.local/bin/serge is a GLOBAL, single-slot resource: exactly one install can
# own the `serge` command. This step used to claim it unconditionally, which is
# two separate bugs.
#
#   1. It silently repoints a working command at this build. That is how the
#      dev box broke: running this installer to test a release aimed `serge` at
#      the release tree. It worked that day (deps had just been installed), then
#      the release tree was REBUILT — release trees ship without node_modules, by
#      design — and every `serge` invocation began dying with
#      `ERR_MODULE_NOT_FOUND: Cannot find package '@orama/orama'`. The breakage
#      landed ~3.5h after the cause, with no edit in between, which is about the
#      worst debugging shape there is.
#
#   2. It defeats the escape hatch the guard above RECOMMENDS. That guard tells
#      you to evaluate a build with SERGE_HOME="$HOME/.serge-trial" — and then
#      this step would point your real `serge` at the trial anyway. A trial that
#      takes over the command is not a trial.
#
# So: a non-default SERGE_HOME never claims the command, and an existing entry
# owned by a DIFFERENT tree is never overwritten without being asked. Both are
# facts read off the filesystem, not guesses.
LINK="$HOME/.local/bin/serge"

# Resolve symlinks the same way the launcher itself does, so "who owns the
# command" is decided by the real path, not by a chain of links.
resolve_path() {
  readlink -f "$1" 2>/dev/null || greadlink -f "$1" 2>/dev/null \
    || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
    || echo "$1"
}

PATH_SKIP=""
if [ "$SERGE_HOME" != "$HOME/.serge" ]; then
  PATH_SKIP="this install uses SERGE_HOME=$SERGE_HOME, not the default ~/.serge.
   A trial install must not become the machine-wide 'serge' command."
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  CUR="$(resolve_path "$LINK")"
  # Owned by THIS install (a re-run or an upgrade) => refresh it silently.
  case "$CUR" in
    "$HERE"/*|"$ENGINE"/*) : ;;
    *) PATH_SKIP="'serge' is already on your PATH from a different install:
     $LINK -> $CUR" ;;
  esac
fi

if [ -n "$PATH_SKIP" ] && [ "$REPLACE_PATH" != "1" ]; then
  say "-- Leaving the 'serge' command alone"
  say "   $PATH_SKIP"
  say ""
  say "   Nothing was changed. Run THIS build directly:"
  say "       $ENGINE_BIN"
  say "   Or give it its own name:"
  say "       ln -sfn '$ENGINE_BIN' \"\$HOME/.local/bin/serge-trial\""
  say "   To take over the 'serge' command anyway:"
  say "       $0 --engine '$ENGINE' --replace-path"
  say ""
else
  say "-- Putting 'serge' on your PATH"
  run "mkdir -p '$HOME/.local/bin'"
  # Point-of-no-return note: this is the step that stranded the dev box, so say
  # where the command used to point BEFORE overwriting it. A one-line receipt is
  # the difference between a ten-second fix and a three-hour hunt.
  if [ -n "$PATH_SKIP" ]; then
    say "   !! Replacing an existing 'serge' command (--replace-path)."
    say "      Was: $LINK -> ${CUR:-?}"
    say "      Now: $LINK -> $ENGINE_BIN"
    say "      Undo:  ln -sfn '${CUR:-?}' '$LINK'"
  fi
  if [ "$OS" = "gitbash" ]; then
    if [ "$DRY" = "0" ]; then
      printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$ENGINE_BIN" > "$LINK"
      chmod +x "$LINK"
    fi
  else
    run "ln -sfn '$ENGINE_BIN' '$LINK'"
  fi
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) say "   NOTE: add ~/.local/bin to your PATH." ;;
  esac
fi

# -------------------------------------------------------------- next steps ---
cat <<EOF

== Installed. Three things left, in this order:

1. Paste your keys (all free tiers — README section 6):
     \$EDITOR $SERGE_HOME/router.env
     \$EDITOR $SERGE_HOME/serge.env        # Tavily key for web search

2. Start the router, then confirm the seats answer:
EOF
case "$OS" in
  linux) echo "     systemctl --user enable --now serge-router.service" ;;
  macos) echo "     launchctl load -w ~/Library/LaunchAgents/com.serge.router.plist" ;;
  gitbash) echo "     (skipped — the launcher spawns the router itself)" ;;
esac
cat <<EOF
     curl -s http://localhost:4000/v1/models | head
     $SERGE_HOME/seat-health.sh      # are the seats REALLY alive? (README §5)

3. Write your constitution — it ships empty on purpose:
     \$EDITOR $SERGE_HOME/CONSTITUTION.md
   Read the preamble at the top first. This is the file that makes Serge yours.

Then:  serge

Nothing was enabled and no key was written. Serge does not sign your commits
(README section 12).
EOF
