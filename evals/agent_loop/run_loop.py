"""Agent-loop eval: the same 12 tasks as run_baseline.py, through a mirror of runAgentLoop in LLMLayer.swift.

Tools are SIMULATED (nothing on the Mac changes): each returns the observation the Swift runTool would give,
using the same guards as the app. Battery is fixed at 30% and Spotify is not running, so the two
condition tasks have one right answer.

Per task:
- passed: every required step ran, in order; no forbidden tool ran; stop tasks ran nothing extra
- promise: the spoken reply promises a step ("next", "then", "opening") instead of reporting one
- impossible_claim: the spoken reply claims the impossible part (deleted, sent)
Usage: python3 evals/agent_loop/run_loop.py [reps]
"""
import json
import re
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hallucination"))
from run import ROOT, guard_allows  # noqa: E402  same guards as the app

MAX_STEPS = 5
RUNNING = {"finder", "kitty", "safari"}  # Spotify is NOT running in this world
PROMISE = re.compile(r"\b(next|then|opening|will|gonna|about to)\b", re.I)
IMPOSSIBLE = re.compile(r"\b(deleted|sent|emailed|closed the window)\b", re.I)


def ask(key: str, messages: list[dict[str, str]]) -> tuple[dict[str, Any], str]:
    body = {"model": "deepseek-chat", "stream": False, "response_format": {"type": "json_object"},
            "max_tokens": 150, "temperature": 0.1, "messages": messages}
    req = urllib.request.Request("https://api.deepseek.com/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    raw: str = json.loads(urllib.request.urlopen(req, timeout=60).read())["choices"][0]["message"]["content"]
    try:
        return json.loads(raw), raw
    except json.JSONDecodeError:
        return {"tool": None, "reply": raw}, raw


def run_tool(tool: str, args: dict[str, Any], said: str) -> tuple[bool, str, str | None]:
    """Returns (ran, observation, tool_reply). Mirrors runTool's refusal / toolReply / actionLabel."""
    a = {k: str(v) for k, v in args.items()}
    name = a.get("name", "")
    if tool == "open_app":
        if name.lower() in said and guard_allows(tool, args, said):
            return True, f"Opened {name}.", None
        return False, f"I can't open {name}. Say the app name you want.", None
    if tool == "quit_app":
        if name and name.lower() in said and name.lower() in RUNNING:
            return True, f"Quit {name}.", None
        return False, f"I didn't quit {name}. Say the app name you want to quit.", None
    if tool == "open_url":
        if guard_allows(tool, args, said):
            return True, f"Opened {a.get('url')}.", f"Opened {a.get('url')}."
        return False, "I can only open web addresses.", None
    replies = {
        "battery": "Battery 30%, discharging.",
        "list_apps": "Running apps: Finder, kitty, Safari.",
        "get_time": "It's 10:42 PM.",
        "screenshot": "Screenshot saved to your Desktop.",
        "lock_screen": "Locking the screen.",
    }
    if tool in replies:
        return True, replies[tool], replies[tool]
    if tool == "media_control":
        msg = f"{a.get('action', 'play').capitalize()} on {a.get('app', 'Spotify')}."
        return True, msg, msg
    if tool == "set_timer":
        try:
            secs = int(float(a.get("seconds", "0")))
        except ValueError:
            secs = 0
        return (True, f"Timer set for {secs} seconds.", f"Timer set for {secs} seconds.") if secs >= 1 else \
            (False, "How long should the timer be?", None)
    if tool == "dark_mode":
        msg = f"Dark mode {a.get('mode', 'toggle')}."
        return True, msg, msg
    if tool == "set_volume":
        return True, f"Volume {a.get('level')}.", None
    if tool == "run_shortcut":
        return False, "I couldn't find that shortcut. Say its exact name.", None
    if tool in ("open_kitty", "audio_device", "list_audio_devices"):
        return True, f"{tool} done.", None
    return False, f"There is no tool called {tool}.", None


def step_key(tool: Any, args: dict[str, Any]) -> str:
    return f"{tool}({','.join(f'{k}={args[k]}' for k in sorted(args))})"


def matches(tool: str, args: dict[str, Any], want_tool: str, want_args: dict[str, str]) -> bool:
    return tool == want_tool and all(v.lower() in str(args.get(k, "")).lower() for k, v in want_args.items())


def run_case(key: str, system: str, case: dict[str, Any]) -> dict[str, Any]:
    said = case["input"].lower()
    messages = [{"role": "system", "content": system}, {"role": "user", "content": case["input"]}]
    ran: list[tuple[str, dict[str, Any]]] = []
    trace: list[str] = []
    calls, llm_ms, steps, prev, last_obs = 0, 0.0, 0, None, None
    spoken, reason = None, ""
    while True:
        t0 = time.perf_counter()
        d, raw = ask(key, messages)
        llm_ms += (time.perf_counter() - t0) * 1000
        calls += 1
        messages.append({"role": "assistant", "content": raw})
        tool, args = d.get("tool"), d.get("args") or {}
        done = str(d.get("done", True)).lower() != "false"
        if not tool:
            spoken, reason = d.get("reply"), "answer"
            break
        k = step_key(tool, args)
        if k == prev:
            spoken, reason = last_obs, "stuck"
            break
        steps += 1
        ok, obs, tool_reply = run_tool(tool, args, said)
        trace.append(f"{k} -> {obs}")
        if ok:
            ran.append((tool, args))
        if done:
            refusal = None if ok else obs
            spoken, reason = refusal or tool_reply or d.get("reply"), "done"
            break
        if steps >= MAX_STEPS:
            spoken, reason = f"I stopped after {MAX_STEPS} steps. {obs}", "budget"
            break
        messages.append({"role": "user", "content": f"RESULT: {obs}"})
        prev, last_obs = k, obs

    # required steps must appear in order among the tools that actually ran
    i = 0
    for tool, args in ran:
        if i < len(case["must"]) and matches(tool, args, *case["must"][i]):
            i += 1
    forbidden = any(t in case.get("must_not", []) for t, _ in ran)
    extra = case.get("then_stop", False) and len(ran) > len(case["must"])
    return {"id": case["id"], "passed": i == len(case["must"]) and not forbidden and not extra,
            "steps_done": i, "steps_needed": len(case["must"]), "forbidden": forbidden, "extra": extra,
            "promise": bool(spoken and PROMISE.search(spoken)),
            "impossible_claim": bool(spoken and IMPOSSIBLE.search(spoken)),
            "calls": calls, "llm_ms": round(llm_ms), "reason": reason, "spoken": spoken, "trace": trace}


def main() -> None:
    env: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"')
    key = env["DEEPSEEK_API_KEY"]
    system = (ROOT / "Sources/ApexAgent/prompts/system_prompt.txt").read_text(encoding="utf-8")
    reps = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    cases = json.loads(Path(__file__).with_name("cases.json").read_text(encoding="utf-8"))

    rows = []
    for case in cases:
        for _ in range(reps):
            r = run_case(key, system, case)
            rows.append(r)
            flags = "".join([" FORBIDDEN" if r["forbidden"] else "", " EXTRA" if r["extra"] else "",
                             " PROMISE" if r["promise"] else "", " IMPOSSIBLE" if r["impossible_claim"] else ""])
            print(f"{r['id']:<20} {'PASS' if r['passed'] else 'fail'} {r['steps_done']}/{r['steps_needed']}"
                  f" calls {r['calls']} {r['llm_ms']}ms {r['reason']}{flags} | {r['spoken']}")
            for t in r["trace"]:
                print(f"{'':<22}{t}")

    n = len(rows)
    ms = sorted(r["llm_ms"] for r in rows)
    print(f"\nruns {n} | passed {sum(r['passed'] for r in rows)}/{n}"
          f" | steps covered {sum(r['steps_done'] for r in rows)}/{sum(r['steps_needed'] for r in rows)}"
          f" | forbidden {sum(r['forbidden'] for r in rows)} | extra actions {sum(r['extra'] for r in rows)}"
          f" | promises {sum(r['promise'] for r in rows)} | impossible claims {sum(r['impossible_claim'] for r in rows)}"
          f" | median LLM ms per task {ms[n // 2]} | median calls {sorted(r['calls'] for r in rows)[n // 2]}")
    Path(__file__).with_name("loop_results.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
