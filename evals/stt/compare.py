import json, re, statistics, sys, time, urllib.request
from pathlib import Path

D = Path(sys.argv[1])
env = {}
for line in Path("/Users/apple/degree/ApexAgent/.env").read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1); env[k] = v.strip().strip('"')
KEY = env["DEEPGRAM_API_KEY"]
URL = ("https://api.deepgram.com/v1/listen?model=nova-2&language=en&encoding=linear16&sample_rate=16000"
       "&channels=1&keywords=ApexAgent:2,Spotify:2,jev:2,exit:3,quit:3")
truth = [l.strip() for l in (D / "phrases.txt").read_text().splitlines() if l.strip()]
NUM = {"30": "thirty"}

def norm(s):
    return [NUM.get(w, w) for w in re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()]

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (r[i-1] != h[j-1]))
    return d[len(r)][len(h)] / max(1, len(r))

apple = {}
for line in (D / "apple_results.jsonl").read_text().splitlines():
    rec = json.loads(line)
    if "file" in rec: apple[rec["file"]] = rec

rows = []   # (system, cond, level, ref, hyp, wer, ms)
for cond in ("clean", "noisy"):
    for i, ref in enumerate(truth, start=1):
        for level in ("quiet", "normal"):
            name = f"p{i}_{level}_NEW_x1"
            raw = (D / f"cond_{cond}" / f"{name}.raw").read_bytes()
            req = urllib.request.Request(URL, data=raw, headers={"Authorization": f"Token {KEY}", "Content-Type": "application/octet-stream"})
            t0 = time.perf_counter()
            out = json.loads(urllib.request.urlopen(req, timeout=60).read())
            ms = (time.perf_counter() - t0) * 1000
            hyp = out["results"]["channels"][0]["alternatives"][0]["transcript"]
            rows.append(("deepgram", cond, level, ref, hyp, wer(ref, hyp), ms))
            a = apple.get(f"{name}.wav", {"text": "", "ms": -1})
            rows.append(("apple", cond, level, ref, a["text"], wer(ref, a["text"]), a["ms"]))

print(f"{'system':9} {'room':6} {'speech':7} {'WER':>6} {'exact':>6} {'median ms':>10}")
for system in ("deepgram", "apple"):
    for cond in ("clean", "noisy"):
        for level in ("quiet", "normal"):
            sel = [r for r in rows if r[0] == system and r[1] == cond and r[2] == level]
            mean_wer = sum(r[5] for r in sel) / len(sel)
            exact = sum(1 for r in sel if r[5] == 0)
            med = statistics.median([r[6] for r in sel])
            print(f"{system:9} {cond:6} {('loud' if level == 'normal' else 'quiet'):7} {mean_wer:6.1%} {exact:3}/{len(sel)} {med:10.0f}")
print("\nmistakes:")
for r in rows:
    if r[5] > 0:
        print(f"  {r[0]:8} {r[1]:5} {('loud' if r[2]=='normal' else 'quiet'):5} {r[3]!r:30} -> {r[4]!r}")
json.dump(rows, open(D / "compare_rows.json", "w"))
