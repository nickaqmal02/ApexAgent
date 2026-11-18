"""Hallucination eval for the cloud router (DeepSeek), using the app's system prompt.

Checks, per call:
- invented_tool: the tool name is not one the app can execute
- wrong_tool: the tool differs from the expected one (null when the app cannot do the request)
- false_claim: the reply claims an action was done when no tool was expected
Usage: python3 evals/hallucination/run.py [temperature] [reps]
"""
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT: Path = Path(__file__).resolve().parents[2]
VALID_TOOLS: set[str] = {"open_app", "quit_app", "set_volume", "battery", "list_apps", "open_kitty", "audio_device", "list_audio_devices"}
CLAIM: re.Pattern[str] = re.compile(r"\b(opened|closed|sent|deleted|restarted|done|launched|quit|playing|searched|switched|set to)\b", re.I)


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


def guard_allows(tool: str, name: str, user_input: str) -> bool:
    import subprocess
    wanted = name.lower()
    if not wanted or wanted not in user_input.lower():   # the app must be named in the request
        return False
    if tool == "open_app":
        folders = ["/Applications", "/System/Applications", str(Path.home() / "Applications")]
        for folder in folders:
            try:
                if any(item.lower() == wanted + ".app" for item in __import__("os").listdir(folder)):
                    return True
            except OSError:
                pass
        return False
    procs = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout.splitlines()
    return any(Path(p.strip()).name.lower().removesuffix(".app") == wanted or p.strip().lower().endswith("/" + wanted + ".app/" + wanted) for p in procs)


def main() -> None:
    env: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k] = v.strip().strip('"')
    key: str = env["DEEPSEEK_API_KEY"]
    system: str = (ROOT / "Sources/ApexAgent/prompts/system_prompt.txt").read_text(encoding="utf-8")
    temperature: float = float(sys.argv[1]) if len(sys.argv) > 1 else 0.9
    reps: int = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    cases: list[dict[str, Any]] = json.loads((Path(__file__).with_name("cases.json")).read_text(encoding="utf-8"))

    total = invented = wrong = claims = parse_fail = executed_wrong = 0
    for case in cases:
        for _ in range(reps):
            d: dict[str, Any] = ask(key, system, case["input"], temperature)
            tool: Any = d.get("tool")
            name: str = str((d.get("args") or {}).get("name", ""))
            reply: str = d.get("reply") or ""
            total += 1
            if tool == "PARSE_FAIL":
                parse_fail += 1
            elif tool is not None and tool not in VALID_TOOLS:
                invented += 1
            if tool != case["tool"]:
                wrong += 1
                print(f"WRONG  {case['input']!r:34} expect={case['tool']} got={tool}")
            if tool in ("open_app", "quit_app") and case["tool"] is None:
                if guard_allows(tool, name, case["input"]):
                    executed_wrong += 1
                    print(f"EXECUTED {case['input']!r:34} {tool} {name!r}")
            if case["tool"] is None and CLAIM.search(reply):
                claims += 1
                print(f"CLAIM  {case['input']!r:34} reply={reply[:90]!r}")
    print("---")
    print(f"temperature={temperature} runs={total}")
    print(f"parse_fail={parse_fail / total:.1%}  invented_tool={invented / total:.1%}  wrong_tool={wrong / total:.1%}  false_claim={claims / total:.1%}")
    print(f"executed_wrong_action={executed_wrong / total:.1%}  (after the app guard: installed for open, running for quit)")


if __name__ == "__main__":
    main()
