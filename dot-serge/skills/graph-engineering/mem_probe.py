#!/usr/bin/env python3
"""Derive a brief-gate probe prompt from the memory corpus this install has.

test_brief_gate.sh needs a prompt guaranteed to overlap a real memory, so it can
check that relevant briefs pull memory into a subagent's world. Hardcoding one
does not survive contact with two different worlds: the prompt named a project
("example-web") that exists only in the public brain's de-identified corpus, so
on an install whose memories use real names it overlapped nothing and the test
failed while the gate was working correctly.

Deriving the terms from whatever memories are actually present makes the probe
match by construction in either world — and it still fails honestly if the
scorer itself breaks, which is the only thing that check is for.

Prints one line of distinctive tokens, or nothing if there is no usable corpus.
"""
import os
import re
import sys

# Words that appear in nearly every memory carry no signal for a scorer that
# weighs rarity — including this project's own vocabulary, which is the whole
# corpus's background noise.
STOP = set("""
the a an and or of to in for on with is was be been it this that from as at by not no
if then than so but when what why how who where which while into onto over under
use used using run runs ran make makes made get gets got set sets does did done
file files fix fixed fixes work works working need needs needed
serge claude code agent model tool tools hook hooks session turn prompt
""".split())


def distinctive(text, limit):
    """Tokens in first-appearance order, deduped, stopwords dropped."""
    seen = set()
    out = []
    for w in re.findall(r"[a-zA-Z][a-zA-Z0-9_-]{3,}", text.lower()):
        if w in STOP or w in seen:
            continue
        seen.add(w)
        out.append(w)
        if len(out) >= limit:
            break
    return out


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else ""
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".md") and n != "MEMORY.md")
    except OSError:
        return 0

    # The richest memory gives the scorer the most to match on. Picking the
    # first alphabetically would make the probe depend on filenames.
    best = []
    for n in names:
        try:
            body = open(os.path.join(d, n), encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        toks = distinctive(body, limit)
        if len(toks) > len(best):
            best = toks

    if best:
        print(" ".join(best))
    return 0


if __name__ == "__main__":
    sys.exit(main())
