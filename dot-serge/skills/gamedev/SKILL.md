---
name: gamedev
description: Build real, shippable games — engine selection (Godot 4 primary/free/OSS, web Kaboom/Phaser, Bevy/Rust, pygame), project scaffolding, a deterministic-sim architecture that is seedable and headless-testable, procedural/free asset pipeline, automated playtesting, and Steam publishing. Free tooling only; every game verified by a real headless run, never "works on my machine" theater.
whenToUse: Use whenever the task is making a game or game component — "build a game", a specific genre (platformer, roguelike, shmup, puzzle, tower defense, RPG), game mechanics/physics/collision, a game loop, procedural generation, level/map design, sprites/tilemaps/SFX for a game, playtesting or balancing, porting a game, or publishing to Steam/itch.io. Also for interactive simulations and toys. Pair with the `steam` skill for publishing. Do NOT use for general graphics programming unrelated to a game.
---

# Gamedev — build shippable games, verified for real

## Honesty about this box
Installed + verified: **Godot 4.7.1** (`godot --headless`), `cargo`/`rustc`, `node`, `bun`,
`python3`. Absent: `love`, `pygame` (pip-installable), `steamcmd` (B.4). Three paths run + verify
**right now**: (a) **Godot 4** desktop/Steam-grade — `templates/godot-headless/` runs a headless
deterministic test (`./gdtest.sh`, exit 0); (b) **web games** (Kaboom/Phaser on `bun`/`node`);
(c) the **engine-agnostic deterministic core** (`templates/deterministic-core/` — 6/6). Never
claim a game "works" from reading code — run the headless test (backtest-before-ship).

## Engine selection

| Want | Use | Why | Ships to |
|---|---|---|---|
| Desktop/console-grade 2D or 3D, one-person-shippable | **Godot 4** (GDScript) | Free/OSS, tiny runtime, `--headless` export, huge scope | Steam, itch, web, mobile |
| Quick 2D game, zero install, instant iteration | **Kaboom.js** / **Phaser** (`bun`) | Runs now, browser-native, trivial to headless-test the sim | Web, itch, Steam via wrapper |
| Max performance / native / ECS, Rust-native team | **Bevy** (`cargo`) | Data-oriented ECS, no GC; heavier build, GPU for render | Steam, native |
| Simple 2D, learning, tooling/CLI game | **pygame** (venv, `SDL_VIDEODRIVER=dummy` for headless) | Simplest loop; great for prototypes | Desktop |

Default: **Godot 4** for anything meant to ship; **Kaboom** to prototype a mechanic in minutes.

## The core doctrine — separate SIM from RENDER (this is the whole game)

Rendering is a thin layer. The **simulation is a pure function of `(seed, inputs)`**. That buys:
- **Reproducibility** — same seed + inputs ⇒ byte-identical run (seed everything; one RNG stream
  per subsystem). See `templates/deterministic-core/game.mjs` (`mulberry32` PRNG; upgrade to a
  ChaCha stream if you need it).
- **Headless testability** — test game logic with **no GPU and no window**: known-answer
  regression (frozen seed+inputs ⇒ frozen signature), determinism, rules, edge cases. See
  `templates/deterministic-core/game.test.mjs` — this is the backtest gate; a broken signature
  means a bug, never "just re-record it."
- **Portable core** — swap Godot/canvas/SDL on top; the tested core never changes.

Fixed-timestep loop, always:
```
accumulator += dt
while (accumulator >= STEP) { state = step(state, input); accumulator -= STEP }  // sim: fixed
render(state, accumulator / STEP)  // render: interpolated, variable
```
Never step the simulation on the render clock — it destroys determinism and makes physics
frame-rate-dependent.

## Architecture patterns (per feature, finish + test before the next)
- **State machine** for game/screen/entity states (menu→play→pause→gameover; idle→patrol→chase).
- **ECS** when entity count/variety grows (Bevy native; a plain `{components: Map}` is enough in JS).
- **Save/load** = serialize `(seed, inputTape)` or the state snapshot; determinism makes replays free.
- **Input**: capture intent (`up/left/fire`) not device keys; lets you record/replay/AI-drive it.
- **Fail loudly**: never silently clamp a bad state — assert invariants in dev builds (score≥0,
  positions in bounds) — the same bounds discipline any probabilistic sim needs.

## Asset pipeline (free / procedural — no paid packs)
**Tested tool** (B.3, verified loading in headless Godot — `test_assetgen.sh` 4/4):
```
~/.serge/office-venv/bin/python3 ~/.serge/skills/gamedev/assetgen.py \
    sprite  out.png --seed 42 [--size 16] [--frames 4]     # mirrored creature sheet
    tileset out.png --seed 5  [--size 16] [--tiles 8]      # one-row tile atlas
    sfx     out.wav --kind jump|coin|hit|explosion|powerup --seed 7
```
- **Deterministic**: same seed ⇒ byte-identical asset — bake the seed into the asset name
  and playtest reports stay reproducible.
- Use it for placeholders and jams; upgrade to hand-art later (Aseprite/Tiled if installed).
- Richer audio: scipy/numpy synthesis directly, or the `music` skill. Export WAV/OGG.
- Loading in Godot headless: `Image.load_from_file("res://sprite.png")` works without an
  import pass; WAVs verify via FileAccess RIFF header (see `test_assetgen.sh` for the pattern).

## Playtest / verify loop (the box isn't checked until this passes)

**Automated — run `playtest.mjs` on any game whose module exports `createGame(seed, opts)` and
`step(state, input)`:**
```bash
node ~/.serge/skills/gamedev/playtest.mjs <game.mjs> [--seeds 5] [--frames 2000] [--budget-us 50]
```
Five checks, exit 0 = shippable, exit 1 = real failure (reported with the **seed + frame to
reproduce**):
1. **Boot smoke** — every seed constructs a usable state (no throw, no non-finite values).
2. **Sustained play** — N frames of reproducible random input: no crash, no NaN/Infinity leak.
3. **Determinism** — identical (seed, input tape) ⇒ identical final state. The regression tripwire.
4. **Input response** — inputs measurably change state (a sim that ignores input is broken, not
   "stable" — this catches a whole class of silently-dead games).
5. **Perf budget** — µs/step vs budget, reported as "steps per 60fps frame".

The template game passes at **0.32µs/step (~52,500 steps per 60fps frame)**.

**The harness itself is negative-controlled**: `./test_playtest.sh` feeds it four deliberately
broken games (crash / NaN-leak / input-deaf / non-deterministic) and asserts each is caught, plus
the known-good game passes — 5/5. A verifier that never fails is theater; this keeps it honest.

Then: **headless unit tests** (`game.test.mjs` / `gdtest.sh`) for rules + frozen known-answers.
Only after all of it do you wire art/audio and call the feature done.

## Scaffolding
- **Deterministic core (runs now)**: copy `templates/deterministic-core/` — a seeded grid game
  (dungeon + coins + win) with a passing headless test. Start every game from this shape.
- **Web (Kaboom)**: `bun add kaboom`; keep the sim in a `game.mjs` core (like the template) and
  let Kaboom only render/handle input. Test the core with `node game.test.mjs`.
- **Godot 4**: `godot --headless --path <proj> --export-release <preset> <out>`; keep pure logic
  in plain GDScript/`.gd` resources testable via `godot --headless -s test.gd`.

## Godot (installed: 4.7.1 at ~/.local/bin/godot)
CPU-only for headless logic/export — no ROCm/GPU, no brick risk. Verified working. Template:
`templates/godot-headless/` (project.godot + sim.gd + test_headless.gd + gdtest.sh). Commands:
- Headless test: `./gdtest.sh` (imports/validates, runs the frozen-known-answer regression).
- Syntax check: `godot --headless --path <proj> --check-only --script res://x.gd`.
- Run a scene headless N frames then quit for a boot-smoke.
- **Packaging a shippable binary** needs export templates (~700 MB `.tpz` for the matching
  version, `godot --headless --export-release <preset> <out>`) — not downloaded yet; pull only
  when actually cutting a build. Headless logic/tests need no templates.

## Shipping to Steam
Use the **`steam` skill** — Steamworks app/depot setup, `steamcmd` upload, build manifests (VDF),
achievements, launch checklist, plus **working keyless market research** (`steam_query.py`: price,
reviews, live player counts, competitor comparison — run it BEFORE building to size the niche).
Note: steamcmd needs a 32-bit loader (not installed here) and a paid Steamworks app; **itch.io +
`butler` is the free path that works from this box today**. Web/Kaboom games ship wrapped
(Electron/NW.js) or to itch directly.

## Anti-patterns (learned the hard way)
- Stepping the sim on `requestAnimationFrame`/render dt → non-deterministic, frame-dependent.
- Global mutable singletons the sim reads → kills reproducibility and testability.
- Shipping a mechanic you only "saw work" once → run the headless test; variance hides bugs.
- Paid asset packs / engines for v1 → free/procedural first (matches Serge's $0 doctrine).
