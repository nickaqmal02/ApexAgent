"""Baseline for the agent loop: what today's single-step ApexAgent does on multi-step tasks.

Today the app makes ONE LLM call and runs at most ONE tool, so a task passes only if
every required step is covered by that single call. This is the number the loop must beat.

Per task it records:
- steps_done: how many required steps (in order) the single call covers (0 or 1 today)
- passed: all required steps covered and no forbidden tool
- forbidden: a must_not tool was chosen
- false_claim: the reply claims a later step that never ran (keyword check, an upper bound)
Usage: python3 evals/agent_loop/run_baseline.py [reps]
"""
import json
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hallucination"))
from run import CLAIM, ROOT, ask  # noqa: E402  reuse the same DeepSeek call and claim regex


def step_matches(tool: str, args: dict[str, Any], want_tool: str, want_args: dict[str, str]) -> bool:
    if tool != want_tool:
        return False
    return all(v.lower() in str(args.get(k, "")).lower() for k, v in want_args.items())


def main() -> None:
    env: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"')
    key: str = env["DEEPSEEK_API_KEY"]
    system: str = (ROOT / "Sources/ApexAgent/prompts/system_prompt.txt").read_text(encoding="utf-8")
    reps: int = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    cases: list[dict[str, Any]] = json.loads(Path(__file__).with_name("cases.json").read_text(encoding="utf-8"))

    rows: list[dict[str, Any]] = []
    for case in cases:
        for _ in range(reps):
            t0 = time.perf_counter()
            out = ask(key, system, case["input"], 0.1)
            ms = (time.perf_counter() - t0) * 1000
            tool: str = str(out.get("tool"))
            args: dict[str, Any] = out.get("args") or {}
            reply: str = str(out.get("reply", ""))
            first_tool, first_args = case["must"][0]
            done = 1 if step_matches(tool, args, first_tool, first_args) else 0
            forbidden = tool in case.get("must_not", [])
            passed = done == len(case["must"]) and not forbidden
            # a claim is false if more than one step is required but only one could run
            false_claim = len(case["must"]) > 1 and bool(CLAIM.search(reply)) and " and " in reply.lower()
            rows.append({"id": case["id"], "tool": tool, "args": args, "reply": reply, "ms": round(ms),
                         "steps_done": done, "steps_needed": len(case["must"]), "passed": passed,
                         "forbidden": forbidden, "false_claim": false_claim})
            print(f"{case['id']:<20} {tool:<14} done {done}/{len(case['must'])}  {'PASS' if passed else 'fail'}"
                  f"{'  FORBIDDEN' if forbidden else ''}{'  CLAIM?' if false_claim else ''}  | {reply}")

    n = len(rows)
    print(f"\ncalls {n} | tasks passed {sum(r['passed'] for r in rows)}/{n}"
          f" | steps covered {sum(r['steps_done'] for r in rows)}/{sum(r['steps_needed'] for r in rows)}"
          f" | forbidden {sum(r['forbidden'] for r in rows)} | possible false claims {sum(r['false_claim'] for r in rows)}"
          f" | median ms {sorted(r['ms'] for r in rows)[n // 2]}")
    Path(__file__).with_name("baseline_results.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
