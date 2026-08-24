#!/usr/bin/env bash
# Tests for reference-resolve.sh — $0, no LLM, no network. Cases 1-3 replay the
# actual prompts from (~/programs/osimage, 2026-07-29) where Serge
# invented an env skeleton and web-searched a same-named product instead of
# reading $HOME/programs/serge-0.1.0/.env.example.
set -uo pipefail
# Cases 3 and 11 dereference $SERGE_HOME directly; under `set -u` the suite died
# there whenever it was not exported (the normal case outside a serge session).
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
HOOK="${SERGE_REFRESOLVE_SCRIPT:-$HOME/.serge/reference-resolve.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/archiso_profile/airootfs/root"
printf '#!/bin/bash\necho hi\n' > "$WS/archiso_profile/airootfs/root/customize_airootfs.sh"
printf 'API_KEY=hunter2-do-not-leak\nDB_URL=postgres://real:secret@host/db\n' > "$WS/.env"
printf 'API_KEY=\nDB_URL=\n' > "$WS/.env.example"

run() { # run <prompt> [cwd]
  python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"UserPromptSubmit","prompt":sys.argv[1],"cwd":sys.argv[2]}))
' "$1" "${2:-$WS}" 2>/dev/null | bash "$HOOK"
}

# 1. the prompt that triggered the web search: a project named, not stood in
out=$(run "ok but what about serges router ON THE NEW OS.... WHAT ARE THE VALUES!?" $HOME/programs/osimage)
# The third assertion used to be `grep -q "$SERGE_HOME"` — the config dir of the
# SESSION. The hook reports the config dir of the PROJECT it resolved, which is
# ~/.serge whichever install is running. Those coincide in a normal install and
# diverge in a test rig (SERGE_HOME=~/.sergio), where the check failed while the
# hook was correct. Assert what the hook actually promises: a live config dir
# that exists.
CFGDIR=$(printf '%s' "$out" | sed -n 's/.*live config dir: \([^ \\"]*\).*/\1/p' | head -1)
if printf '%s' "$out" | grep -q "serge-0.1.0" \
   && printf '%s' "$out" | grep -q "\.env\.example" \
   && [ -n "$CFGDIR" ] && [ -d "$CFGDIR" ]; then
  ok "cross-project name → repo path + .env.example + live config dir"
else bad "project resolution missed (out=${out:0:400})"; fi

# 2. same output warns off web-searching a same-named product
if printf '%s' "$out" | grep -q "not a web-search topic"; then
  ok "cross-project block carries the don't-google-the-name line"
else bad "missing web-search guard"; fi

# 3. explicit real path in the prompt → EXISTS + key count
# (greps stay ASCII: additionalContext is JSON, so the em dash arrives —-escaped)
out=$(run "what about the rest? it should look like this: $SERGE_HOME/router.env" $HOME/programs/osimage)
if printf '%s' "$out" | grep -q "router.env" && printf '%s' "$out" | grep -q "EXISTS" \
   && printf '%s' "$out" | grep -qE "[0-9]+ keys"; then
  ok "named real path → EXISTS with size/lines/keys"
else bad "explicit path resolution missed (out=${out:0:300})"; fi

# 4. invented path whose basename is real → says so and names the real one
out=$(run "update $HOME/programs/osimage/airootfs/root/customize_airootfs.sh please" "$WS")
if printf '%s' "$out" | grep -q "DOES NOT EXIST"; then
  ok "invented path → flagged DOES NOT EXIST"
else bad "invented path not flagged (out=${out:0:300})"; fi

# 4b. relative multi-segment path (the commonest way a human names a file)
out=$(run "why does archiso_profile/airootfs/root/customize_airootfs.sh fail?")
if printf '%s' "$out" | grep -q "EXISTS"; then
  ok "relative path → resolved and confirmed"
else bad "relative path unresolved (out=${out:0:250})"; fi

# 4c. relative path that is wrong, but the basename is real → says where it is
out=$(run "patch airootfs/root/customize_airootfs.sh for me")
if printf '%s' "$out" | grep -q "NOT at that path" && printf '%s' "$out" | grep -q "archiso_profile"; then
  ok "wrong relative path → names the real location"
else bad "wrong relative path not corrected (out=${out:0:250})"; fi

# 4d. non-path slashes must never produce a line
out=$(run "does it run 24/7 and/or on weekends in this big project?")
if [ -z "$out" ]; then ok "'24/7' and 'and/or' → no false path lines"
else bad "false positive on non-path slashes (out=${out:0:200})"; fi

# 5. bare filename → resolved to a real workspace path
out=$(run "check customize_airootfs.sh for the serge install block")
if printf '%s' "$out" | grep -q "archiso_profile/airootfs/root/customize_airootfs.sh"; then
  ok "bare filename → resolved to real path"
else bad "bare filename unresolved (out=${out:0:300})"; fi

# 6. the template request that got invented from memory
out=$(run "just leave those env variables empty and create skeleton so we can fill them up with new api keys")
if printf '%s' "$out" | grep -q "already ships artifacts" && printf '%s' "$out" | grep -q "\.env\.example"; then
  ok "template request → existing env artifacts listed"
else bad "template discovery missed (out=${out:0:300})"; fi

# 7. NEVER leak values, only counts — the whole point of citing a live config dir
if printf '%s' "$out" | grep -q "hunter2\|postgres://"; then
  bad "LEAKED a secret value into context"
else ok "no file contents/secrets in output (counts only)"; fi

# 8. standing inside the project → don't resolve its own name (no new info)
out=$(run "fix the serge router config" $HOME/programs/serge-0.1.0)
if ! printf '%s' "$out" | grep -q "Other projects named"; then
  ok "own project not resolved (no self-noise)"
else bad "resolved the cwd's own project"; fi

# 9. ordinary prompt with no references → completely quiet
out=$(run "why is this slower than it was yesterday?")
if [ -z "$out" ]; then ok "no references → quiet (zero tokens)"
else bad "false positive on plain prompt (out=${out:0:200})"; fi

# 10. generic words must not resolve as projects
out=$(run "check the tests and docs for the app config")
if ! printf '%s' "$out" | grep -q "Other projects named"; then
  ok "generic words (tests/docs/app/config) → no project match"
else bad "generic word matched a project (out=${out:0:200})"; fi

# 11. output stays inside the size cap
out=$(run "compare $SERGE_HOME/router.env and serge and openclaude and create an env skeleton template with api keys" $HOME/programs/osimage)
len=$(printf '%s' "$out" | wc -c)
if [ "$len" -lt 2600 ]; then ok "output capped (${len} bytes incl. JSON envelope)"
else bad "output too large (${len} bytes)"; fi

# 12. off-switch
out=$(SERGE_REFRESOLVE_DISABLE=1 run "what about serges router config")
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 13. malformed input → fail open
out=$(printf 'not json' | bash "$HOOK")
if [ -z "$out" ]; then ok "malformed input → fails open"
else bad "malformed input produced output"; fi

echo
echo "reference-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
