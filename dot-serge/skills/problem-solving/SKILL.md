---
name: problem-solving
description: Getting from an ill-defined ask to a solution — restate the problem in terms of inputs, outputs and invariants; find the constraint that actually binds; reduce to a problem that is already solved; work one concrete example by hand before writing code; solve the smaller version first. Includes the checks that catch a solution to the wrong problem before it ships.
whenToUse: Use BEFORE writing code for anything that is not a mechanical edit — a feature whose shape is unclear, a "make it faster" with no measurement, a design with more than one plausible answer, a task where you notice you are about to start typing to figure out what you think. Also when stuck, when the third attempt is failing, or when a solution works but you cannot say why. NOT for bugs — that is `debugging`, which starts from a symptom; this starts from a goal.
---

# Problem solving — understand it before you solve it

`debugging` starts from a symptom and works backwards. This starts from a goal
and works forwards. The failure it prevents is different too: not a wrong fix,
but a correct solution to a problem nobody had.

## 1. Restate it until it is checkable

Write the problem as **inputs → outputs**, plus the invariants that must hold.
If you cannot, you do not yet know what you are building.

- What exactly comes in? Types, ranges, volume, and what a malformed one looks like.
- What must come out? Including for empty, one, and the largest realistic input.
- What must stay true throughout? (Balances never negative. Order preserved.
  Every write is either visible or absent, never half.)
- How will I know it worked? Name the observation, not the feeling.

A restatement the asker would not recognise means you are solving something
else. Say your restatement back to them when the gap matters.

## 2. Find the binding constraint

Most stated requirements are not binding. Exactly one or two usually are, and
they determine the shape of the answer.

Ask: if I relaxed this, would the solution change? If no, it is not binding —
stop designing around it. Common real ones: a latency budget, a memory ceiling,
an API rate limit, an ordering guarantee, "must be reversible", "must not lose
data on crash".

## 3. Reduce to something already solved

Before inventing: is this a known problem wearing different words?

| It smells like | It probably is |
|---|---|
| "find matching pairs across two lists" | a hash join — index one side |
| "the newest N of a huge stream" | a bounded heap, not a sort |
| "did I already see this?" | a set, or a bloom filter if memory binds |
| "do these depend on each other?" | a graph — topological sort or cycle detection |
| "keep it consistent across two writes" | a transaction, or one idempotent write |
| "the same expensive answer repeatedly" | memoisation, and a cache-invalidation question |
| "too many combinations to try" | dynamic programming, or a greedy proof |

Reducing costs minutes and saves an implementation. Not finding a reduction is
information too — it means the problem is genuinely yours and deserves care.

## 4. Work one example by hand

Take a real input. Produce the correct output on paper, without writing code.

This is the highest-yield step and the most often skipped. It catches
misunderstood requirements, off-by-ones, and the edge case you would otherwise
find in production. If you cannot do it by hand, you cannot specify it, and code
will not rescue you.

Then pick the awkward one — empty, one element, duplicate keys, the boundary —
and do it again.

## 5. Solve the smaller version first

If the full problem resists, solve a version you can finish:

- the same problem with one input instead of many
- without the concurrency, without the cache, without the retries
- the brute-force answer, which is also your correctness oracle

Then make it general. A working narrow solution tells you where the real
difficulty is; a stalled general one tells you nothing.

## 6. Check the answer, not your confidence

- Does it produce the hand-worked example? Run that first, before anything else.
- Does it hold the invariants from step 1 — including on the failure path?
- What is its cost as the input grows? (`complexity` prices it; do not estimate.)
- What happens when the part that can fail, fails?
- Can you state why it is correct in one sentence? If not, you have a solution
  that happens to pass, which is a different thing.

## When you are stuck

Stuck means the approach is wrong, not that you need more of it.

- **State the obstacle in one sentence.** Vagueness here means the problem is
  not understood, so go back to step 1.
- **Solve a different problem**: the reverse, a special case, or the version
  where the hard constraint is removed. Then ask what the removed constraint
  actually costs.
- **Work backwards** from the required output to what must precede it.
- **Name what you assumed.** Stuckness usually lives in an assumption you did
  not know you made. List them; check the cheapest one first.
- **Three failed attempts is a signal, not bad luck.** Stop and re-read step 1 —
  you are probably solving the wrong problem correctly.

## Failure modes

- **Coding to think.** Typing to discover what you believe. Think first; the
  editor is for a decision already made.
- **Solving the general case first.** Building the framework before the one
  case that was asked for.
- **Anchoring on the first idea.** It is a draft. Name a second approach and
  why you rejected it — cannot name one means you have not understood the
  problem yet.
- **Accepting the ask literally.** "Make it faster" is a symptom. Ask what is
  slow and by how much before optimising anything.
- **Confusing a passing test with a correct solution.** Tests you wrote from
  the same misunderstanding will pass.
