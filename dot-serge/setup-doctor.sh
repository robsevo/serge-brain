#!/usr/bin/env bash
#
# setup-doctor.sh — tell a new user exactly what to do next, on THEIR system.
#
# install.sh already reports what is missing. What it does not do is give you
# the command that fixes it here, or check whether the keys you filled in
# actually work. Both of those are where setup stalls: "MISSING litellm" is a
# fact, not an instruction, and a typo'd key fails much later as a routing
# error that looks like a Serge bug.
#
# Safe to run repeatedly. Reads; never writes.
#
#   bash setup-doctor.sh          check everything
#   bash setup-doctor.sh --keys   only validate keys (fast, no network probes for tools)
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
KEYS_ONLY=0
[ "${1:-}" = "--keys" ] && KEYS_ONLY=1

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; X=$'\033[0m'
else
  B=''; D=''; G=''; Y=''; R=''; C=''; X=''
fi
ok()   { printf '  %sok%s    %s\n' "$G" "$X" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$Y" "$X" "$1"; }
bad()  { printf '  %sno%s    %s\n' "$R" "$X" "$1"; }
hint() { printf '        %s%s%s\n' "$C" "$1" "$X"; }

# ── which system is this, and what installs things here ────────────────────
OS="unknown"; PM=""; PM_INSTALL=""
case "$(uname -s)" in
  Darwin) OS="macos"; PM="brew"; PM_INSTALL="brew install" ;;
  Linux)
    OS="linux"
    # Ordered by specificity: a system with both apt and snap is an apt system.
    if   command -v pacman  >/dev/null 2>&1; then PM="pacman"; PM_INSTALL="sudo pacman -S"
    elif command -v apt-get >/dev/null 2>&1; then PM="apt";    PM_INSTALL="sudo apt install"
    elif command -v dnf     >/dev/null 2>&1; then PM="dnf";    PM_INSTALL="sudo dnf install"
    elif command -v zypper  >/dev/null 2>&1; then PM="zypper"; PM_INSTALL="sudo zypper install"
    elif command -v apk     >/dev/null 2>&1; then PM="apk";    PM_INSTALL="sudo apk add"
    fi ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
esac

printf '\n%sSerge setup doctor%s  %s(%s%s)%s\n\n' "$B" "$X" "$D" "$OS" "${PM:+, $PM}" "$X"

# Package names differ per manager; a generic "install node" is what makes
# people give up. Only the ones that actually differ are listed.
pkg_for() {
  case "$1:$PM" in
    node:brew)    echo "node" ;;
    node:pacman)  echo "nodejs npm" ;;
    node:apt)     echo "nodejs npm" ;;
    node:dnf)     echo "nodejs npm" ;;
    node:*)       echo "nodejs" ;;
    python3:apt)  echo "python3" ;;
    python3:*)    echo "python3" ;;
    curl:*)       echo "curl" ;;
    git:*)        echo "git" ;;
    *)            echo "$1" ;;
  esac
}

fail=0
need() { # need <cmd> <why>
  if command -v "$1" >/dev/null 2>&1; then ok "$1  $D$2$X"; return 0; fi
  bad "$1 — $2"
  if [ -n "$PM_INSTALL" ]; then hint "$PM_INSTALL $(pkg_for "$1")"
  elif [ "$OS" = "windows" ]; then hint "winget install $1   (or use WSL, which is the tested path)"
  else hint "install $1 with your system's package manager"; fi
  fail=1
}

if [ "$KEYS_ONLY" -eq 0 ]; then
  printf '%sRequired%s\n' "$B" "$X"
  need node    "the engine runs on it"
  need python3 "hook helpers"
  need curl    "health checks"
  need git     "cloning and the doc gates"

  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${major:-0}" -ge 22 ]; then ok "node >= 22 (found $major)"
    else
      bad "node is v$major — the engine needs >= 22"
      case "$PM" in
        brew)   hint "brew upgrade node" ;;
        pacman) hint "sudo pacman -S nodejs" ;;
        apt)    hint "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install nodejs" ;;
        *)      hint "nodejs.org, or use nvm: nvm install 22" ;;
      esac
      fail=1
    fi
  fi

  # litellm is the router every seat goes through, so it is required in
  # practice even though nothing imports it.
  if command -v litellm >/dev/null 2>&1; then ok "litellm  ${D}the model router$X"
  else
    bad "litellm — the router every seat goes through"
    if command -v uv >/dev/null 2>&1; then hint "uv tool install 'litellm[proxy]'"
    else hint "curl -LsSf https://astral.sh/uv/install.sh | sh   # then:"
         hint "uv tool install 'litellm[proxy]'"; fi
    fail=1
  fi

  printf '\n%sOptional%s %s(Serge runs without these)%s\n' "$B" "$X" "$D" "$X"
  for pair in "semgrep:static analysis in the code gates" \
              "rg:faster search" \
              "jq:nicer hook debugging" \
              "systemctl:runs the router as a service"; do
    c="${pair%%:*}"; w="${pair#*:}"
    if command -v "$c" >/dev/null 2>&1; then ok "$c  $D$w$X"
    else warn "$c — $w"; [ -n "$PM_INSTALL" ] && hint "$PM_INSTALL $c"; fi
  done

  if [ "$OS" = "macos" ]; then
    printf '\n%smacOS note%s\n' "$B" "$X"
    if command -v gtimeout >/dev/null 2>&1; then ok "coreutils (GNU timeout/stat/sha256sum)"
    else warn "coreutils — hooks use GNU flag syntax"; hint "brew install coreutils"; fi
  fi
  if [ "$OS" = "windows" ]; then
    printf '\n%sWindows note%s\n' "$B" "$X"
    warn "hooks are bash scripts — WSL2 is the tested path, not PowerShell"
    hint "wsl --install   then run this again inside WSL"
  fi
fi

# ── keys ───────────────────────────────────────────────────────────────────
printf '\n%sAPI keys%s  %s(%s/keys.env)%s\n' "$B" "$X" "$D" "$SH" "$X"

# keys.env last: it is the single file a new user fills, and it must win over
# the blank router.env a fresh install ships.
for f in "$SH/serge.env" "$SH/router.env" "$SH/keys.env"; do
  [ -f "$f" ] && set -a && . "$f" 2>/dev/null && set +a
done

# Live probe. A key that is present but wrong is worse than a missing one: it
# fails later as a routing error that looks like a Serge bug.
probe() { # probe <name> <url> <auth-header> <signup-url> <note>
  local name="$1" url="$2" auth="$3" signup="$4" note="$5"
  local val="${!name:-}"
  if [ -z "$val" ]; then
    warn "$name not set  $D$note$X"
    hint "get one: $signup"
    return 1
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 12 -H "$auth: ${auth_prefix}${val}" "$url" 2>/dev/null || echo 000)"
  case "$code" in
    200|201) ok "$name  ${D}verified$X" ; return 0 ;;
    401|403) bad "$name is set but REJECTED (HTTP $code) — wrong or revoked key"
             hint "replace it: $signup"; return 1 ;;
    402)     bad "$name is out of credit (HTTP 402) — valid, but it cannot serve a request"
             hint "top up or use another provider: $signup"; return 1 ;;
    429)     warn "$name is rate-limited right now (HTTP 429) — it works, just throttled"; return 0 ;;
    000)     warn "$name set, could not reach the provider (offline?)"; return 0 ;;
    *)       warn "$name set, provider answered HTTP $code"; return 0 ;;
  esac
}

working=0
auth_prefix="Bearer "
probe GEMINI_API_KEY     "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY:-x}" \
                         "X-Ignore" "https://aistudio.google.com/apikey" \
                         "free tier, no card — backs both default seats" && working=$((working+1))
probe OPENROUTER_API_KEY "https://openrouter.ai/api/v1/key" "Authorization" \
                         "https://openrouter.ai/keys" "free tier, many models" && working=$((working+1))
probe MISTRAL_API_KEY    "https://api.mistral.ai/v1/models" "Authorization" \
                         "https://console.mistral.ai/api-keys" "free tier" && working=$((working+1))

printf '\n%sOptional keys%s\n' "$B" "$X"
# `|` separates the fields: every URL contains `:`, so it cannot also be the
# separator — that split produced "//app.tavily.com/home:web search".
for pair in "TAVILY_API_KEY|https://app.tavily.com/home|web search (WebFetch works without it)" \
            "CEREBRAS_API_KEY|https://cloud.cerebras.ai|very fast inference" \
            "ZAI_API_KEY|https://z.ai|GLM-4.7-Flash, 200K context" \
            "OPENROUTER_PAID_API_KEY||paid OpenRouter lane, only if you want it"; do
  n="${pair%%|*}"; rest="${pair#*|}"; u="${rest%%|*}"; w="${rest#*|}"
  if [ -n "${!n:-}" ]; then ok "$n  $D$w$X"
  else warn "$n — $w"; [ -n "$u" ] && hint "$u"; fi
done

# ── verdict ────────────────────────────────────────────────────────────────
printf '\n%s%s%s\n' "$B" "────────────────────────────────────────────────────────" "$X"
if [ "$working" -ge 1 ] && [ "$fail" -eq 0 ]; then
  printf '  %sReady.%s %d provider key(s) working. Start with: %sserge%s\n\n' "$G" "$X" "$working" "$C" "$X"
  exit 0
fi
if [ "$working" -eq 0 ]; then
  printf '  %sNo working provider key.%s You need ONE — any one — to start.\n' "$R" "$X"
  printf '  %sEasiest: Gemini. Free, no card, and it backs both default seats.%s\n' "$D" "$X"
  hint "https://aistudio.google.com/apikey"
  printf '  Then put it in %s%s/keys.env%s and run this again.\n\n' "$C" "$SH" "$X"
fi
[ "$fail" -ne 0 ] && printf '  %sInstall the missing tools above, then run this again.%s\n\n' "$Y" "$X"
exit 1
