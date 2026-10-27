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

## Tue 27 Oct : 1101H
### **THE GOAL: STREAM MICROPHONE AUDIO TO DEEPGRAM AND GET REAL TIME TRANSCRIPTS BACK**
### **THE WALL: WE HIT EVERY LAYER OF STACK SIMULTANOUSLY. WE SAW SOCKET IS NOT CONNECTED, BAD RESPONSE FROM SERVER, EMPTY TRANSCRIPTS 
### **THE ROOT CAUSE ANALYSIS: WHY WE HAD TO ADJUST THE SIGNAL FIRST ?, WHY NOT JUST GIVE ALL ROW PIPELINE TO DEEPGRAM ? BECAUSE DEEPGRAM API'S IS A STRICT CONTRACT. IT EXPECTS EXACTLY LINEAR16 (INT16 PCM) AT 16000HZ.MY MAC MICROPHONE OUTPUTS FLOAT32 AT 44100HZ. IF I JUST PIPE THE MIC DIRECTLY TO DEEPGRAM: IF I JUST PIPE DIRECTLY MIC TO DEEPGRAM, THE SERVER RECEIVES DATA IT CANNOT PARSE, RESULTING IN A "BAD RESPONSE" AND AN IMMEDIATE CONNECTION DROP. I HAD TO BUILD THE SIGNAL CONVERSION LAYER BEFORE THE NETWORK LAYER.

#### LAYER 1 [ HARDWARE + DATA ]
~ If I wanna explain this articulately I will say: My mac's microphone captures air pressure and turns it into raw numbers: Float32 values at 44100 samples per second. But the AI brain can't digest all that data: It's too heavy. So I wrote a manual conversion loop that downsample it to 16000 samples per second and compressed it into int16 bytes. I literally multiplied the sound waves by 20 to boost the volume so the brain could hear it clearly ~

#### LAYER 2 [ THE NERVOUS SYSTEM (NETWORK)]
"I couldn't just send this audio over a normal HTTP request. If I did, I'd have to wait 2 seconds for a response every time I spoke. That's laggy. Instead, I opened a WebSocket—a persistent, real-time connection to Deepgram's servers. I stream thousands of binary audio chunks per second over this socket, and in return, they stream text back to me instantly."

#### LAYER 3 [ THE BRAIN ( AI + LOGIC )]
"When the text comes back from Deepgram, it goes into my harness, The harness doesn't think it just routes. It checks if we are online. If yes, it sends the text to GLM (the cloud LLM). If we're offline, it sends it to Ollama (the local model running on my RAM). The LLM reads the text, decides what tool to use, and returns a JSON instruction like {"tool": "set_volume"}"



##### THIS PIPELINE ARCHITECTURE FOLLOWS THE "OSI/TCP-IP MODEL" THAT'S THE REAL ARCHITECTURE

Layer 1: Physical Layer (Hardware)
What it is: Air pressure from your voice hitting the microphone diaphragm.
In ApexAgent: The microphone converts sound into an electrical signal, which the Mac's Audio Controller turns into raw Float32 data. This is the physical wire.
Layer 2: Data Link Layer (Local Framing)
What it is: Organizing raw bits into frames on your local machine.
In ApexAgent: AVAudioEngine taps the hardware and packages the raw data into AVAudioPCMBuffer objects (chunks of 1024 frames). It gives you a structured "bucket" of audio instead of a continuous stream of bits.
Layer 3: Network Layer (IP Routing)
What it is: Addressing and routing packets across the internet.
In ApexAgent: When you send data to Deepgram, DNS resolves api.deepgram.com to an IP address (like 208.185.49.101). Your binary audio bytes are wrapped in IP packets, routed through your Wi-Fi router, across Malaysia's internet infrastructure, to Deepgram's servers in the US.
Layer 4: Transport Layer (TCP / Ports)
What it is: Reliable data delivery, ports, and connection management.
In ApexAgent: This is the TCP connection your WebSocket runs on. TCP guarantees that every single audio chunk arrives at Deepgram in order, with no drops. Deepgram listens on Port 443 (WSS). If a packet drops, TCP handles retransmitting it so your audio doesn't glitch.
Layer 5: Application Layer (Protocols & APIs)
What it is: The actual app logic—HTTP, WebSockets, JSON.
In ApexAgent: This is where the WebSocket Protocol lives.
You perform a WebSocket Handshake (an HTTP GET upgrade).
You send binary frames (your Int16 audio bytes).
You receive text frames (Deepgram's JSON transcripts).
This is also where your Swift JSONDecoder and LLMResponse structs parse the data.
How to articulate this to your friends:
Friend: "How does TCP/IP fit into your agent?"

You: "People think TCP/IP is just textbook theory. I use every layer of it in ApexAgent."

Physical/Data: I tap the Mac's microphone bus to capture raw Float32 audio buffers.
Network: The audio bytes are wrapped in IP packets and routed from my Mac to Deepgram's servers.
Transport: I rely on TCP to guarantee that thousands of audio chunks per second arrive at Deepgram in order, on Port 443, without dropping.
Application: On top of that TCP connection, I use the WebSocket protocol to stream binary frames. When Deepgram replies, I parse the JSON payload at this layer.
So I don't just "use an API." I wire the physical hardware to the transport layer to the application protocol. I build the entire stack.

That is exactly how a senior network engineer talks.


- **APPROACHING WEBSOCKET ISSUES** for deepgram
- but first thing first why do we need adjusting the signal setup first why not give all pipeline to deepgram ?
: here is the answer, written deeply from my understanding, 
- what we actually checked: socket is not connected ? /, Bad Response from server: /, Empty Transcripts, App crashes,
- 
