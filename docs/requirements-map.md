# ApexAgent vs AI engineer requirements

Status key: **Covered** (evidence exists in the repo), **Partial** (some evidence, gap noted), **Gap** (no evidence yet).

## Required

| Requirement | Evidence in this repo | Status | Next evidence |
|---|---|---|---|
| Software engineering fundamentals: data structures, design, testing | Struct-based records, queues, router design. `Tests/ApexAgentTests/ApexAgentTests.swift` is still the Xcode template | Gap (testing) | Tests for `logTrace`, the router output parser, and the duplicate-call fix |
| Python and API integration | `evals/router/run.py` calls the Ollama HTTP API | Covered | Add the latency timing to the same script |
| Hands-on LLM prototype, explain integration and testing | Voice and text router (`LLMLayer.swift`), 60-run eval in `evals/router/` | Covered | Eval results written into the notebook |
| Systematic debugging | Duplicate `executeDecision` call (`LLMLayer.swift:336`, `ApexAgent.swift:141`); duplicate history append (`LLMLayer.swift:88`, `:311`) | Partial | Each bug gets a failing test, then a fix, then a passing test |
| Turn problems into requirements, prompts, acceptance criteria | Problem statement draft; eval cases with expected tool and args | Covered | Acceptance thresholds written before measuring |
| Critically evaluate AI-generated output | Router failure `close the window` → `quit_app "Window"` (3 of 3 runs), kept in the eval record | Covered | Fix plus a must-pass case |
| Git | Repository with commit history | Covered | None |

## Preferred

| Area | Evidence in this repo | Status |
|---|---|---|
| AI agents and tool calling | JSON tool calls mapped to handlers in `executeDecision` | Covered |
| RAG, embeddings, vector DB, MCP | None | Gap (not planned; add only if a measured need appears) |
| Independent AI project | ApexAgent, built from scratch | Covered |
| Concurrency | `brainQueue`, `traceQueue`, main-thread dispatch | Covered |
| AI evaluation: accuracy, latency, reliability | Router eval: 100% valid JSON, 95% tool match, 1.5 s median (`evals/router/baseline-*.txt`) | Partial (latency study pending) |
| JS/TS or Go, Docker, Kafka, OpenSearch | None | Gap (not planned) |

## Gaps to close, in order

1. **Real tests.** Replace the template in `Tests/ApexAgentTests/` with tests for the logger and the router output parser.
2. **Latency study.** Per-stage timing, 20 runs per case, committed benchmark log, table computed in the notebook.
3. **Bug fixes with tests.** Duplicate `executeDecision` call, then duplicate history append.
