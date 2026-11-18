"""Hallucination and routing eval for the cloud router (DeepSeek), using the app's system prompt.

Per call it checks:
- parse_fail: the reply is not valid JSON
- invented_tool: a tool name the app cannot execute
- wrong_tool: a tool outside the expected set (null = the app cannot do the request)
- wrong_args: the right tool, but an expected argument is missing or different
- executed_wrong_action: a tool would actually run (after the app's guards) for a request that should do nothing
- false_claim: the reply claims success for a request that should do nothing (keyword check, an upper bound)
Usage: python3 evals/hallucination/run.py [temperature] [reps]
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT: Path = Path(__file__).resolve().parents[2]
VALID_TOOLS: set[str] = {"open_app", "quit_app", "set_volume", "battery", "list_apps", "open_kitty", "audio_device",
                         "list_audio_devices", "get_time", "media_control", "open_url", "set_timer", "run_shortcut",
                         "screenshot", "lock_screen", "dark_mode"}
CLAIM: re.Pattern[str] = re.compile(r"\b(opened|closed|sent|deleted|restarted|done|launched|quit|playing|searched|switched|set to)\b", re.I)
SHORTCUTS: list[str] = subprocess.run(["shortcuts", "list"], capture_output=True, text=True).stdout.splitlines()


def ask(key: str, system: str, user: str, temperature: float) -> dict[str, Any]:
    body: dict[str, Any] = {"model": "deepseek-chat", "stream": False, "response_format": {"type": "json_object"},
                            "max_tokens": 150, "temperature": temperature,
                            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    req = urllib.request.Request("https://api.deepseek.com/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    out: dict[str, Any] = json.loads(urllib.request.urlopen(req, timeout=60).read())
    raw: str = out["choices"][0]["message"]["content"]
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"tool": "PARSE_FAIL", "reply": raw}


def guard_allows(tool: str, args: dict[str, Any], user_input: str) -> bool:
    """Mirrors the app's guards: True if the tool would actually run."""
    said: str = user_input.lower()
    if tool in ("open_app", "quit_app"):
        name: str = str(args.get("name", "")).lower()
        if not name or name not in said:
            return False
        if tool == "open_app":
            folders = ["/Applications", "/System/Applications", str(Path.home() / "Applications")]
            return any(name + ".app" in [i.lower() for i in os.listdir(f)] for f in folders if os.path.isdir(f))
        procs = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout.splitlines()
        return any(Path(p.strip()).name.lower() == name for p in procs)
    if tool == "open_url":
        url: str = str(args.get("url", ""))
        return url.startswith(("https://", "http://"))
    if tool == "run_shortcut":
        match = next((s for s in SHORTCUTS if s.lower() == str(args.get("name", "")).lower()), None)
        words = [w for w in (match or "").lower().split() if len(w) >= 3]
        return bool(match) and bool(words) and all(w in said for w in words)
    return tool in VALID_TOOLS


def main() -> None:
    env: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"')
    key: str = env["DEEPSEEK_API_KEY"]
    system: str = (ROOT / "Sources/ApexAgent/prompts/system_prompt.txt").read_text(encoding="utf-8")
    temperature: float = float(sys.argv[1]) if len(sys.argv) > 1 else 0.1
    reps: int = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    cases: list[dict[str, Any]] = json.loads(Path(__file__).with_name("cases.json").read_text(encoding="utf-8"))

    n = parse_fail = invented = wrong = wrong_args = executed_wrong = claims = 0
    for case in cases:
        expected: list[Any] = case["tool"] if isinstance(case["tool"], list) else [case["tool"]]
        for _ in range(reps):
            d: dict[str, Any] = ask(key, system, case["input"], temperature)
            tool: Any = d.get("tool")
            args: dict[str, Any] = d.get("args") or {}
            reply: str = d.get("reply") or ""
            n += 1
            if tool == "PARSE_FAIL":
                parse_fail += 1
            elif tool is not None and tool not in VALID_TOOLS:
                invented += 1
            if tool not in expected:
                wrong += 1
                print(f"WRONG_TOOL {case['input']!r:34} expect={expected} got={tool} args={args}")
            elif case.get("args"):
                for k, want in case["args"].items():
                    if str(want).lower() not in str(args.get(k, "")).lower():
                        wrong_args += 1
                        print(f"WRONG_ARGS {case['input']!r:34} {k}: expected to contain {want!r}, got {args.get(k)!r}")
                        break
            if expected == [None] and tool not in (None, "PARSE_FAIL") and guard_allows(tool, args, case["input"]):
                executed_wrong += 1
                print(f"EXECUTED   {case['input']!r:34} {tool} {args}")
            if expected == [None] and CLAIM.search(reply):
                claims += 1
    print("---")
    print(f"temperature={temperature} cases={len(cases)} runs={n}")
    print(f"parse_fail={parse_fail / n:.1%}  invented_tool={invented / n:.1%}  wrong_tool={wrong / n:.1%}  "
          f"wrong_args={wrong_args / n:.1%}  executed_wrong_action={executed_wrong / n:.1%}  false_claim={claims / n:.1%}")


if __name__ == "__main__":
    main()
