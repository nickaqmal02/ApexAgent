# ApexAgent v0.2 — Build Log

**Date:** October 24, 2026 (Day 3+)
**Phase:** 3 (Online/Offline Fallback) + improvements from v0.1
**Status:** 🔨 In Progress

---

## Targets To Achieve

### From v0.1 Evaluation

1. **Conversation history** — LLM remembers previous turns
   - `conversationHistory` array stores user + assistant messages
   - Send full history each call so "72" has context after "increase volume"

2. **Faster model** — switch from qwen3:8b to qwen2.5:3b
   - 8B: ~15 tok/s, 5GB, response 3-9s
   - 3B: ~40 tok/s, 2GB, response ~1-3s
   - Trade: slightly less smart, but fast enough for conversational feel

3. **Online/offline fallback** — dual LLM provider
   - `isOnline()` — checks internet with 2s timeout
   - `askGLM()` — cloud LLM (DeepSeek API, fast, smart)
   - `askOllama()` — local LLM (offline, private)
   - `askLLM()` — router that picks provider based on connectivity
   - If GLM fails → fallback to Ollama automatically

4. **User context in system prompt**
   - "User is Nik, final-year CS student at UPNM, casual tone, vim user"
   - LLM knows you, matches your vibe, not generic robot

5. **Stronger prompt — act, don't ask**
   - "If the user says 'increase volume' without a number, pick a reasonable default (e.g., 75)"
   - Don't ask clarifying questions — just do it

6. **Ollama keep-alive**
   - `"keep_alive": "30m"` in request body
   - Model stays in RAM between calls → no cold start penalty

---

## Evaluation

### Metrics To Compare v0.1 → v0.2

| Metric | v0.1 | v0.2 Target |
|---|---|---|
| Response time (cold) | 9-13s | < 5s |
| Response time (warm) | 3-5s | < 2s |
| Conversation memory | ❌ None | ✅ Full history |
| Online mode | ❌ Ollama only | ✅ GLM + fallback |
| Offline mode | ✅ Ollama | ✅ Ollama (unchanged) |
| User context | ❌ Generic | ✅ Knows Nik |
| Prompt quality | Asks questions | Acts directly |

### Evaluation Checklist

```
☐ "increase the volume" → LLM picks set_volume(75) without asking
☐ "72" after previous → LLM understands context (set_volume to 72)
☐ Turn off wifi → falls back to Ollama, still works
☐ Turn on wifi → uses GLM, faster response
☐ LLM responds casually, knows Nik's name and context
☐ Response time < 2s when using GLM (cloud)
☐ Response time < 3s when using Ollama (warm, 3B model)
```

---

## What Needs Improvement (For v0.3)

_Placeholder — will be filled after v0.2 evaluation_

- Voice input (STT) — Phase 4
- Voice output (TTS) — Phase 5
- macOS UI (SwiftUI) — Phase 6
- ???
