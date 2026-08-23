---
name: tabarnak
description: Autonomous story-by-story build loop — drive a prd.json to done, one fresh session per story, a box checked only when its test exits 0
---

# Tabarnak — autonomous build loop

Load the `tabarnak` skill now and follow it. It is the operating manual for this
command; everything below is the contract you are being held to, not a summary
of it.

$ARGUMENTS

## What this is

A PRD becomes a queue. Each iteration is a **fresh session** that takes one
story, builds it, and proves it. The loop ends when every box is checked or
nothing is left that can be checked.

## The three rules that make it safe to leave running

**A box is checked by a test, never by an opinion.** A story is done when its
deterministic test command exits 0. Not when the code looks right, not when you
believe it works. A story without a runnable test command is not ready to enter
the loop — say so and stop rather than inventing a criterion.

**Each iteration starts fresh.** No conversation carries over. Everything the
next iteration needs to know has to be written down — that is what
`progress.txt` is for. Learnings, dead ends, and decisions go there in the
moment; anything you leave in your head is gone at the end of the turn.

**One story per iteration.** The whole point is a bounded blast radius. Finishing
early does not earn you the next story.

## Before the first iteration

Read the PRD and check it can actually drive a loop:

- Every story has acceptance criteria and a **test command**.
- The test command fails *now*, for the right reason. A test that already passes
  proves nothing about the work you are about to do.
- Stories are ordered so a dependency lands before what needs it.

If any of that is missing, fix the PRD first and say what you changed. Starting
a loop on an unrunnable PRD burns a session per story to discover it.

## When a story will not pass

Three failed attempts on the same story is a signal, not bad luck — stop and
escalate rather than burning the remaining iterations on it. Write what you
learned to `progress.txt`, leave the box unchecked, and move on or halt. An
honest unchecked box is worth more than a checked one nobody can trust.
