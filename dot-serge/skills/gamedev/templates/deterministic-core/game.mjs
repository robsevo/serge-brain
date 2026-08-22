// Engine-agnostic DETERMINISTIC game core — the pattern every Serge game is built on.
//
// Why this shape: rendering (canvas/Godot/SDL) is a thin layer on top; the SIMULATION is a
// pure function of (seed, inputs). That makes the game (a) reproducible — same seed + same
// inputs => byte-identical run, and (b) HEADLESS-TESTABLE without a GPU or a window (see
// game.test.mjs). The discipline: seedable RNG, fixed timestep,
// deterministic step, no hidden global state. Swap the render layer per engine; keep this core.

// --- seedable PRNG (mulberry32): fast, deterministic, reproducible. Upgrade to a ChaCha impl
// if you need cryptographic-quality streams; mulberry32 is plenty for game logic. ---
export function mulberry32(seed) {
  let a = seed >>> 0
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export const DIRS = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0], wait: [0, 0] }

// Deterministic dungeon: same seed => same grid. 0 = floor, 1 = wall. Border always wall.
export function generateDungeon(seed, w = 16, h = 12, wallChance = 0.28) {
  const rng = mulberry32(seed)
  const grid = []
  for (let y = 0; y < h; y++) {
    const row = []
    for (let x = 0; x < w; x++) {
      const border = x === 0 || y === 0 || x === w - 1 || y === h - 1
      row.push(border ? 1 : rng() < wallChance ? 1 : 0)
    }
    grid.push(row)
  }
  grid[1][1] = 0 // guarantee the spawn is walkable
  return grid
}

export function createGame(seed, opts = {}) {
  const w = opts.w ?? 16, h = opts.h ?? 12
  const grid = generateDungeon(seed, w, h)
  const rng = mulberry32(seed ^ 0x9e3779b9) // separate stream for entity logic
  // Place N coins on floor tiles, deterministically.
  const coins = new Set()
  let placed = 0
  while (placed < (opts.coins ?? 6)) {
    const x = 1 + Math.floor(rng() * (w - 2)), y = 1 + Math.floor(rng() * (h - 2))
    const key = `${x},${y}`
    if (grid[y][x] === 0 && !(x === 1 && y === 1) && !coins.has(key)) { coins.add(key); placed++ }
  }
  return { grid, w, h, player: { x: 1, y: 1 }, coins, score: 0, tick: 0, done: false }
}

// Pure fixed-timestep step: (state, input) -> next state. No rendering, no I/O.
export function step(state, input) {
  if (state.done) return state
  const [dx, dy] = DIRS[input] ?? DIRS.wait
  const nx = state.player.x + dx, ny = state.player.y + dy
  if (state.grid[ny]?.[nx] === 0) { state.player.x = nx; state.player.y = ny } // walls block
  const key = `${state.player.x},${state.player.y}`
  if (state.coins.has(key)) { state.coins.delete(key); state.score++ }
  state.tick++
  if (state.coins.size === 0) state.done = true // win: all coins collected
  return state
}

// Run a full scripted game headlessly and return a compact, hashable signature.
export function run(seed, inputs, opts = {}) {
  const s = createGame(seed, opts)
  for (const inp of inputs) step(s, inp)
  return {
    tick: s.tick, score: s.score, coinsLeft: s.coins.size, done: s.done,
    player: { ...s.player },
    // stable signature of the whole final state for known-answer regression tests
    signature: `${seed}|${s.tick}|${s.score}|${s.coins.size}|${s.player.x},${s.player.y}|${s.done}`,
  }
}
