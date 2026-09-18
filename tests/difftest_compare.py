#!/usr/bin/env python3
"""Compare musashi88k's core output against the MC88100 hardware oracle.

Two ways to supply the oracle (reference) values:

  1. tests/difftest_oracle.json -- a checked-in file of expected results, each
     one gathered from the nono LUNA-88k emulator via the nono-mcp `run_test_case`
     tool (or hand-derived from the MC88100 User's Manual and confirmed on
     hardware). This lets the comparison run with no live emulator attached.

  2. (future) a live nono connection. The nono debugger console is only reachable
     through the MCP server, so the live path is driven interactively during a
     Kiro session; the results are then frozen into difftest_oracle.json.

Each oracle entry keys on the case `name` and records the fields that matter
for that instruction class:
  - "r4"/"r7"/...: expected value of a specific result register (decimal)
  - "cf":  expected carry flag after the step (0/1)
  - "exc": expected exception vector (-1 = none)

Only the fields present in the oracle entry are checked, so a carry test asserts
CF while a bit-field test asserts only its destination register. This mirrors
how the nono oracle reports just the *changed* registers.

Usage:
    difftest_runner tests/difftest_cases.json tests/difftest_ours.json
    python3 tests/difftest_compare.py tests/difftest_ours.json tests/difftest_oracle.json
"""

import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    ours = {c["name"]: c for c in load(sys.argv[1])}
    oracle = load(sys.argv[2])

    passed = failed = 0
    for exp in oracle:
        name = exp["name"]
        got = ours.get(name)
        if got is None:
            print(f"  MISSING  {name}: no result from our core")
            failed += 1
            continue

        problems = []
        for key, want in exp.items():
            if key == "name":
                continue
            if key == "cf":
                have = got["cf"]
            elif key == "exc":
                have = got.get("exc", -1)
            elif key.startswith("r"):
                have = got["regs"][key]
            else:
                continue
            if have != want:
                problems.append(f"{key}: got {have} want {want}")

        if problems:
            print(f"  FAIL  {name}: " + "; ".join(problems))
            failed += 1
        else:
            print(f"  ok    {name}")
            passed += 1

    print(f"\n{passed} passed, {failed} failed ({len(oracle)} oracle cases)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
