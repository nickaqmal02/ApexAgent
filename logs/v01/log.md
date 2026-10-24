# ApexAgent v0.1 — Build Log

**Date:** October 24, 2026 (Day 1-2)
**Phase:** 1 + 2 (Command Router + Local LLM)
**Status:** ✅ Working

---

## What Was Built

### Phase 1 — Command Router (Day 1)

Terminal REPL with hardcoded command routing.

- `runShell()` — Process + Pipe wrapper for macOS shell commands
- `parseInput()` — splits "open spotify" into ("open", ["spotify"])
- `printHelp()` — iterates command registry, displays formatted help
- 6 handlers: `handleOpen`, `handleQuit`, `handleVolume`, `handleBattery`, `handleListApps`
- REPL loop with `guard`-based input validation
- ANSI color setup (cyan prompt, colored output)

**Commands working:**
- `open spotify` → launches app via `open -a`
- `quit safari` → quits app via `osascript`
- `volume 50` → sets volume via `osascript` (clamped 0-100)
- `battery` → reads via `pmset -g batt`
- `list apps` → lists via `ps aux`
- `help` → shows command registry
- `exit` → clean shutdown

### Phase 2 — Local LLM Integration (Day 2)

Replaced hardcoded routing with local LLM (Ollama + qwen3:8b).

- `LLMResponse` struct (Decodable) — defines JSON shape from LLM
- `askOllama()` — sends POST to localhost:11434/api/chat
  - Uses `DispatchSemaphore` to make async URLSession synchronous
  - Parses nested JSON: Ollama → message → content → LLMResponse
  - Response time tracking with `Date().timeIntervalSince()`
- `executeDecision()` — routes LLM intent to correct handler
- System prompt with tool catalog and JSON-only response format
- `format: "json"` in request body forces valid JSON output
- `temperature: 0.1` for consistent JSON

**What works:**
- "open spotify" → LLM picks `open_app` → Spotify opens ✅
- "set volume to 50" → LLM picks `set_volume` → volume changes ✅
- "hey what's up" → LLM returns `{tool: null}` → conversation ✅

---

## Evaluation

### What Went Well ✅

- Swift learning curve was fast — mapped Python concepts quickly
- `Process()` + `Pipe()` pattern works cleanly for shell commands
- Ollama integration was straightforward (one URL change from DeepSeek pattern)
- `DispatchSemaphore` pattern for sync networking — solved the async-in-REPL problem
- JSON decoding with `Decodable` struct is clean and type-safe
- Response time tracking gives visibility into LLM latency

### What Needs Improvement ❌

![ChatHistoryIssue](media/ChatHistoryProblem.Heic)

1. **No conversation history** — LLM has no memory between turns
   - "increase the volume" → "72" doesn't work (LLM forgets context)
   - Fix: maintain `conversationHistory` array, send full history each call

2. **Slow response time (9-13s)** — qwen3:8b is too heavy for quick commands
   - First call: ~5s (cold start, model loads into RAM)
   - Warm calls: ~3-5s (still slow for conversational feel)
   - Fix: try `qwen2.5:3b` (smaller, ~40 tok/s vs ~15 tok/s)
   - Fix: add `"keep_alive": "30m"` to keep model in RAM

3. **LLM asks clarifying questions instead of acting**
   - "increase the volume" → "Sure, how much?" instead of just doing it
   - Fix: stronger system prompt — "pick a reasonable default if unspecified"
   - Fix: conversation history (so "72" has context)

4. **No online/offline detection**
   - Always uses Ollama, even when internet is available
   - Fix: `isOnline()` checker + GLM API fallback (Phase 3)

5. **No user context in prompt**
   - LLM responds like a generic assistant, doesn't know Nik
   - Fix: inject user profile into system prompt

6. **Swift 6 concurrency warning**
   - `var result` captured in async closure triggers `#SendableClosureCaptures`
   - Fix: `nonisolated(unsafe) var result` or restructure with `DispatchQueue.main.sync`

7. **No error recovery**
   - If Ollama is not running, user gets a vague error
   - Fix: check Ollama health before first call, show clear message

8. **Single file (200+ lines)** — getting unwieldy
   - Fix: split into ShellRunner.swift, Handlers.swift, LLMLayer.swift (when stable)

---

## What To Improve in v0.2

| # | Improvement | Priority | Effort |
|---|---|---|---|
| 1 | Conversation history (memory) | HIGH | Low |
| 2 | Faster model (qwen2.5:3b) | HIGH | Low |
| 3 | Online/offline fallback (GLM + Ollama) | HIGH | Medium |
| 4 | User context in system prompt | MEDIUM | Low |
| 5 | Stronger prompt (act, don't ask) | MEDIUM | Low |
| 6 | Error recovery (Ollama not running) | LOW | Low |
| 7 | Split into multiple files | LOW | Low |
| 8 | Swift 6 concurrency fix | LOW | Low |

---

## Key Learnings

- `Process()` doesn't search PATH — must use full executable paths (`/usr/bin/open`)
- Swift is case-sensitive: `readLine()` not `readline()`
- `guard let` unwraps optionals for the rest of the scope (unlike `if let`)
- `DispatchSemaphore` is the bridge between async URLSession and sync REPL
- `defer { semaphore.signal() }` guarantees unblocking on every exit path
- Ollama's `format: "json"` forces valid JSON — essential for tool calling
- `temperature: 0.1` keeps JSON consistent (high temp = creative = broken JSON)
- LLMs are stateless — "memory" is just re-sending old messages each call

---

## Files

```
Sources/ApexAgent/
└── ApexAgent.swift  (200+ lines, single file)
```

## Commands Reference

```bash
# Build
swift build

# Run
swift run

# Start Ollama (must be running for LLM features)
ollama serve

# Pull a different model
ollama pull qwen2.5:3b
```
