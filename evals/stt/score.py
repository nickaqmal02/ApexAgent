import json, re, sys, urllib.request
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
    words = re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()
    return [NUM.get(w, w) for w in words]

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (r[i-1] != h[j-1]))
    return d[len(r)][len(h)] / max(1, len(r))

def transcribe(path):
    req = urllib.request.Request(URL, data=path.read_bytes(),
                                 headers={"Authorization": f"Token {KEY}", "Content-Type": "application/octet-stream"})
    out = json.loads(urllib.request.urlopen(req, timeout=60).read())
    return out["results"]["channels"][0]["alternatives"][0]["transcript"]

results = {}
for i, ref in enumerate(truth, start=1):
    for level in ("quiet", "normal"):
        for variant in ("OLD", "NEW_x1", "NEW_x4"):
            hyp = transcribe(D / "out" / f"p{i}_{level}_{variant}.raw")
            results.setdefault((variant, level), []).append((ref, hyp, wer(ref, hyp)))

print(f"{'pipeline':8} {'level':7} {'mean WER':>8} {'exact':>6}")
for (variant, level), rows in sorted(results.items()):
    mean = sum(r[2] for r in rows) / len(rows)
    exact = sum(1 for r in rows if r[2] == 0)
    print(f"{variant:8} {level:7} {mean:8.1%} {exact:4}/{len(rows)}")
print("\nmistakes:")
for (variant, level), rows in sorted(results.items()):
    for ref, hyp, w in rows:
        if w > 0:
            print(f"  {variant:7} {level:6} {ref!r:32} -> {hyp!r}")
