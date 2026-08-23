# Installing Serge

Five steps, about ten minutes. You need **one** free API key — not all of them.

```
1. install the prerequisites     2. clone BOTH repos into a folder called serge
3. build the engine, run install.sh
4. put one key in one file       5. run the doctor, then start
```

If you get stuck at any point, run `bash ~/.serge/setup-doctor.sh`. It checks
your system, tells you the exact command to fix whatever is missing, and
verifies your keys against the real providers.

---

## 1. Prerequisites

| What | Why |
|---|---|
| **Node.js ≥ 22** | runs the engine |
| **Python 3** | hook helpers |
| **git**, **curl** | cloning, health checks |
| **LiteLLM** | the model router |

<details>
<summary><b>Linux</b></summary>

```bash
# Debian / Ubuntu
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install nodejs
sudo apt install python3 git curl

# Arch
sudo pacman -S nodejs npm python git curl

# Fedora
sudo dnf install nodejs npm python3 git curl
```
</details>

<details>
<summary><b>macOS</b></summary>

```bash
brew install node python3 git curl
brew install coreutils          # hooks use GNU timeout/stat/sha256sum
brew install flock              # only if you want the background loops
```
</details>

<details>
<summary><b>Windows</b></summary>

Serge's hooks are bash scripts. **Use WSL2** — it is the tested path.

```powershell
wsl --install
```

Then open Ubuntu and follow the Linux instructions inside it.
</details>

**LiteLLM**, on every platform:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh    # if you don't have uv
uv tool install 'litellm[proxy]'
```

---

## 2. Get both repos

Serge is **two repositories**, and you need both:

| Repo | What it is |
|---|---|
| **serge-brain** | the config: hooks, gates, skills, agents, router seats |
| **serge-engine** | the runtime that reads them and runs the agent loop |

Put them side by side inside one folder called `serge`:

```bash
mkdir serge && cd serge

git clone https://github.com/robsevo/serge-brain.git
git clone https://github.com/robsevo/serge-engine.git
```

You should now have exactly this:

```
serge/
├── serge-brain/     ← you run install.sh from in here
└── serge-engine/
```

Everything below assumes you are inside that `serge/` folder.

## 3. Build the engine, then install

```bash
cd serge-engine
npm install
npm run build

cd ../serge-brain
./install.sh --engine ../serge-engine
```

The `--engine ../serge-engine` is the part that pairs them — it is why they have
to sit side by side.

This populates `~/.serge`, puts `serge` on your `PATH`, and creates blank
credential files. **It writes no keys and starts no services** — those are the
next two steps, deliberately separate so nothing runs before you have looked at
it.

---

## 4. Get one key

Open `~/.serge/keys.env`. Every key has its signup URL right there in the file,
so you never have to come back here.

**Start with Gemini.** It is free, needs no credit card, and it backs both seats
Serge uses by default — one key is a complete working install.

| Provider | Where | Card needed? | Why you might add it |
|---|---|---|---|
| **Gemini** ← start here | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | no | free tier, backs both default seats |
| OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | no (for `:free` models) | many models behind one key |
| Mistral | [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys) | no | free tier, strong coding models |
| Cerebras | [cloud.cerebras.ai](https://cloud.cerebras.ai) | no | very fast inference |
| Z.AI | [z.ai](https://z.ai) | no | GLM-4.7-Flash, 200K context |
| Tavily *(optional)* | [app.tavily.com](https://app.tavily.com/home) | no | web **search**. `WebFetch` reads any URL without it |

Getting the Gemini key: sign in with a Google account → **Get API key** →
**Create API key** → copy it. That is the whole process.

Paste it in:

```bash
# ~/.serge/keys.env
GEMINI_API_KEY=AIza...your-key-here
```

Adding more providers is optional and additive: Serge routes across whatever you
give it and falls back when one is rate-limited, so more keys means fewer
stalls, not more capability.

### Already had Serge before `keys.env` existed?

Your keys are in `router.env` and `serge.env`. Collect them into the single file:

```bash
bash ~/.serge/migrate-keys.sh
```

It copies what it finds and leaves both originals alone — the launcher reads all
three, so nothing breaks either way. Safe to run twice.

### Free tier running out?

Any provider takes a **spare account**. Add the same name with `_2`:

```bash
GEMINI_API_KEY=first-account
GEMINI_API_KEY_2=second-account
```

```bash
bash ~/.serge/rotate-keys.sh
```

That duplicates every seat backed by that provider so it exists once per
account. LiteLLM load-balances across them and moves to the other when one is
throttled or spent — a used-up free tier slows you down instead of stopping you.
`_3` and `_4` work the same way. Re-runnable, and it checks the config still
parses before telling you to restart.

---

## 5. Check, then start

```bash
bash ~/.serge/setup-doctor.sh
```

It reads your system — `pacman`, `apt`, `brew`, `dnf`, WSL — and prints the
exact install command for anything missing. Then it checks each key **against
the real provider**, so a typo shows up here rather than later as a routing
error that looks like a Serge bug. It distinguishes a missing key from a wrong
one from one that is valid but out of credit.

```
Serge setup doctor  (linux, pacman)

Required
  ok    node >= 22 (found 22)
  ok    litellm  the model router

API keys  (~/.serge/keys.env)
  ok    GEMINI_API_KEY  verified

────────────────────────────────────────────
  Ready. 1 provider key(s) working. Start with: serge
```

Start the router, then Serge:

```bash
systemctl --user enable --now serge-router     # Linux
# macOS: launchctl load ~/Library/LaunchAgents/com.serge.router.plist

serge
```

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| `serge: command not found` | reopen your shell, or add `~/.local/bin` to `PATH` |
| every request fails | is the router up? `curl localhost:4000/health` |
| "no working provider key" | `bash ~/.serge/setup-doctor.sh --keys` names the reason per key |
| a model 429s constantly | free tier throttling — add a second account, see step 4 |
| hooks misbehave on macOS | `brew install coreutils` — they use GNU flag syntax |
| anything on Windows | use WSL2; native PowerShell is not a tested path |

`setup-doctor.sh` is safe to run any time. It only reads.
