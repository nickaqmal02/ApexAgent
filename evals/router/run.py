"""Baseline eval for the offline text router (Ollama, same system prompt and options as askOllama).

Usage: python3 evals/router/run.py [model] [reps]
Scores: valid JSON, tool exact match, and args (name contains expected, level within 0-100 and equal when given).
"""
import json
import statistics
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

ROOT: Path = Path(__file__).resolve().parents[2]
PROMPT_PATH: Path = ROOT / "Sources/ApexAgent/prompts/system_prompt.txt"
CASES_PATH: Path = Path(__file__).with_name("cases.json")
OLLAMA_URL: str = "http://localhost:11434/api/chat"
VALID_TOOLS: set[str] = {"open_app", "quit_app", "set_volume", "battery", "list_apps", "open_kitty", "audio_device", "list_audio_devices"}


def ask(model: str, system: str, user: str) -> tuple[str, float]:
    body: dict[str, Any] = {
        "model": model,
        "stream": False,
        "think": False,
        "format": "json",
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": 0.1},
    }
    req = urllib.request.Request(OLLAMA_URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    start: float = time.perf_counter()
    with urllib.request.urlopen(req, timeout=120) as resp:
        content: str = json.loads(resp.read())["message"]["content"]
    return content, time.perf_counter() - start


def score(case: dict[str, Any], raw: str) -> tuple[bool, bool, bool]:
    try:
        parsed: dict[str, Any] = json.loads(raw)
    except json.JSONDecodeError:
        return False, False, False
    tool: Any = parsed.get("tool")
    tool_ok: bool = tool == case["tool"] and (tool is None or tool in VALID_TOOLS)
    args: dict[str, Any] = parsed.get("args") or {}
    args_ok: bool = True
    for key, expected in case["args"].items():
        got: Any = args.get(key)
        if got is None:
            args_ok = False
        elif key == "level":
            args_ok = args_ok and str(got) == str(expected)
        else:
            args_ok = args_ok and str(expected).lower() in str(got).lower()
    if case["tool"] == "set_volume" and not case["args"]:
        args_ok = str(args.get("level", "")).isdigit()
    return True, tool_ok, args_ok


def main() -> None:
    model: str = sys.argv[1] if len(sys.argv) > 1 else "qwen3:8b"
    reps: int = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    system: str = PROMPT_PATH.read_text(encoding="utf-8")
    cases: list[dict[str, Any]] = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    total: int = 0
    json_ok_n: int = 0
    tool_ok_n: int = 0
    args_ok_n: int = 0
    latencies: list[float] = []
    for case in cases:
        for _ in range(reps):
            raw, secs = ask(model, system, case["input"])
            json_ok, tool_ok, args_ok = score(case, raw)
            total += 1
            json_ok_n += json_ok
            tool_ok_n += tool_ok
            args_ok_n += args_ok
            latencies.append(secs)
            mark: str = "PASS" if tool_ok and args_ok else "FAIL"
            print(f"{mark} | {case['input']!r:38} expect={case['tool']!s:18} got={raw[:110]}")
    print("---")
    print(f"model={model} runs={total}")
    print(f"valid_json={json_ok_n / total:.0%} tool_match={tool_ok_n / total:.0%} args_match={args_ok_n / total:.0%}")
    print(f"latency median={statistics.median(latencies):.2f}s max={max(latencies):.2f}s")


if __name__ == "__main__":
    main()
