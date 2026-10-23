# ApexAgent

> A macOS native voice agent built in Swift. Local LLM inference. Online/offline fallback. 100% terminal-built. One week, hardcore mode.

## Demo

**Demo video:** [Watch the demo](media/simpledemo.mp4)
![ApexAgent Demo](media/simpledemo.gif)

Phase 1 & 2: Command router + local LLM (Ollama/qwen3:8b) understanding natural language.

## What Is This

ApexAgent is a personal AI assistant for macOS — think Jarvis, but running entirely on your machine. It listens to your voice, understands natural language, controls your Mac, and speaks back. No cloud dependency required.

Built from scratch in Swift. No Xcode. No tutorials. Just `vim` + `swift build` + `swift run`.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      ApexAgent                           │
│                                                          │
│   Voice Input (STT)                                     │
│     ├─ Online:  Deepgram Flux (streaming WebSocket)      │
│     └─ Offline: Apple Speech framework (on-device)      │
│             ↓                                            │
│   Intent Understanding (LLM)                            │
│     ├─ Online:  GLM API (cloud)                         │
│     └─ Offline: Ollama + Qwen3 8B (local)               │
│             ↓                                            │
│   Tool Execution                                         │
│     ├─ Process (shell commands: open, quit, volume)     │
│     └─ Accessibility API (click UI elements in apps)    │
│             ↓                                            │
│   Voice Output (TTS)                                    │
│     ├─ Online:  Deepgram Aura-2 (natural voice)          │
│     └─ Offline: AVSpeechSynthesizer (built-in)          │
└─────────────────────────────────────────────────────────┘
```

The agent auto-detects network status. Online → cloud APIs (smarter, faster). Offline → local models (private, no internet needed). The user never notices the switch.

## One Week Sprint — Build Plan

| Day | Phase | Goal | Done When |
|---|---|---|---|
| 1 (Thu) | Command Router | Terminal REPL with hardcoded commands | `open spotify` opens Spotify |
| 2 (Fri) | Local LLM | Ollama integration, natural language routing | "crank up the volume" → volume 80 |
| 3 (Sat) | Online/Offline Fallback | GLM + Ollama auto-switch | Kill wifi → still works |
| 4 (Sun) | Voice Input (STT) | Apple Speech + Deepgram | Speak "open spotify" → it opens |
| 5 (Mon) | Voice Output (TTS) | AVSpeech + Deepgram Aura-2 | Agent speaks back |
| 6 (Tue) | macOS UI | SwiftUI menu bar chat app | Not a terminal anymore |
| 7 (Wed) | Polish + Demo | Bug fix, record demo video | Portfolio-ready |

## What I Will Learn

### Swift Language

- **Optionals** (`?` `!` `if let`) — the core Swift concept, no Python equivalent
- **Structs vs Classes** — value types vs reference types, when to use each
- **Enums with associated values** — Swift's superpower, Python has nothing like this
- **Protocols** — like Python ABCs but enforced at compile time
- **Closures** — Swift's lambdas, trailing closure syntax
- **Error handling** (`try/catch/throw`) — different from Python's try/except
- **Async/await** — concurrency, continuations, actors
- **String interpolation** (`\(variable)`) — like f-strings but different syntax

### Data Structures

- **Arrays** — `map`, `filter`, `forEach`, `contains`
- **Dictionaries** — `Dictionary(uniqueKeysWithValues:)`, optional value access
- **Sets** — fast O(1) lookup
- **Tuples** — fixed-size, named elements
- **Custom structs** — building your own data containers
- **Enums as state machines** — modeling intent with associated values

### macOS Frameworks

- **Process** — run shell commands from Swift (`open`, `osascript`, `pmset`)
- **SwiftUI** — declarative UI: `View`, `@State`, `@Binding`, `VStack`, `HStack`
- **AppKit integration** — menu bar, window lifecycle, `MenuBarExtra`
- **AVFoundation** — `AVAudioEngine` for mic capture, `AVAudioPlayer` for playback
- **AVSpeechSynthesizer** — built-in text-to-speech, no API key needed
- **Speech framework** — `SFSpeechRecognizer`, on-device streaming STT
- **Network framework** — `NWPathMonitor` for online/offline detection
- **Accessibility API** — read and click UI elements in other apps

### Networking

- **URLSession** — HTTP POST/GET to Ollama and GLM APIs
- **JSONDecoder/Encoder** — parse LLM JSON responses
- **WebSocket** — streaming audio to Deepgram Flux
- **Async networking** — `async/await` with `URLSession.data`
- **Protocol-oriented design** — `LLMProvider` protocol, swap implementations at runtime

### AI Engineering

- **Local LLM inference** — Ollama, model quantization, memory budget on M1 Pro
- **Prompt engineering** — system prompts for JSON intent extraction
- **Tool calling** — LLM picks a tool from a registry, fills arguments, executes
- **Two-mode architecture** — online (cloud) vs offline (local), graceful degradation
- **Voice pipeline** — STT → LLM → tool → TTS, the full loop
- **Streaming responses** — SSE-style partial results from both STT and LLM

### Software Engineering

- **Swift Package Manager** — `Package.swift`, dependencies, targets
- **Terminal-first workflow** — `vim` + `swift build` + `swift run`, no IDE
- **Git discipline** — daily commits, one feature per commit
- **Protocol-based architecture** — `LLMProvider`, `STTProvider`, `TTSProvider`
- **Error handling at boundaries** — user input, network, audio, shell commands
- **TCC permissions** — microphone, accessibility, automation consent

## Tech Stack

| Component | Technology | Cost |
|---|---|---|
| Language | Swift 6 | Free |
| Build | Swift Package Manager | Free |
| Editor | Vim | Free |
| Local LLM | Ollama + Qwen3 8B | Free |
| Cloud LLM | GLM API (DeepSeek-compatible) | Cheap |
| Online STT | Deepgram Flux | Free $200 credit |
| Offline STT | Apple Speech framework | Free |
| Online TTS | Deepgram Aura-2 | Free $200 credit |
| Offline TTS | AVSpeechSynthesizer | Free |
| Vector store (future) | ChromaDB / MLX | Free |

## Hardware

- **Machine:** MacBook Pro M1 Pro (32GB unified memory, 16 cores)
- **Memory bandwidth:** 200 GB/s
- **Local LLM budget:** ~24GB usable for model + context
- **Metal support:** Metal 4

## Project Structure

```
ApexAgent/
├── Package.swift                  # SPM manifest
├── Sources/
│   └── ApexAgent/
│       ├── ApexAgent.swift         # entry point
│       ├── (future files...)
│       │   ├── CommandRouter.swift     # Phase 1 — parse + route commands
│       │   ├── ShellRunner.swift        # Phase 1 — Process() wrapper
│       │   ├── OllamaProvider.swift     # Phase 2 — local LLM
│       │   ├── GLMProvider.swift        # Phase 3 — cloud LLM
│       │   ├── LLMProvider.swift        # Phase 3 — protocol
│       │   ├── NetworkMonitor.swift     # Phase 3 — online/offline
│       │   ├── AudioRecorder.swift      # Phase 4 — mic capture
│       │   ├── SpeechProvider.swift     # Phase 4 — Apple STT
│       │   ├── DeepgramSTT.swift        # Phase 4 — Deepgram STT
│       │   ├── SpeechSynthesizer.swift  # Phase 5 — AVSpeech TTS
│       │   ├── DeepgramTTS.swift        # Phase 5 — Deepgram TTS
│       │   └── ContentView.swift       # Phase 6 — SwiftUI
├── Tests/
│   └── ApexAgentTests/
└── README.md
```

## Reference Projects

- **Computah** (`~/degree/PersonalAgentic/computah/`) — Swift macOS notch app with Deepgram + Jev + Accessibility API. Used as reference for voice, LLM calls, and app structure. Not forked — patterns are studied and reimplemented.

## The Rule

```
No tutorials. No courses. No "let me watch one more video."

  Write code → build → fix errors → repeat.

  The compiler is your teacher.
  The terminal is your classroom.
  The deadline is your motivator.
```

## Author

**Nik** (@nickaqmal02) — Final-year CS student, aspiring AI Engineer. Building this to learn native macOS development and local LLM integration in one focused week.

## License

MIT
