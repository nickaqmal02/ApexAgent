#!/usr/bin/env python3
"""Study report: reads data/study_sessions.csv and writes data/study_report.html.

Run from the project root:   python3 scripts/study_report.py
Then it opens the report in your browser. Standard library only (no pandas/matplotlib).
The report is a local file under data/ (gitignored) because it holds your study history.
"""
import csv
import json
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = ROOT / "data" / "study_sessions.csv"
OUT_PATH = ROOT / "data" / "study_report.html"
DAYS = 14            # days shown in the daily chart
QUICK_MIN = 1.0      # sessions shorter than this are taps / tests, not real attempts


def load():
    rows = []
    with CSV_PATH.open(newline="") as f:
        for r in csv.DictReader(f):
            start = datetime.fromisoformat(r["started_at"])
            rows.append({
                "subject": r["subject"],
                "planned": float(r["planned_min"]),
                "actual": float(r["actual_min"]),
                "start": start,
                "end": datetime.fromisoformat(r["ended_at"]),
                "done": r["completed"] == "1",
            })
    return rows


def summarise(rows):
    # Subject order = first time studied, so each subject keeps its colour as data grows
    subjects = list(dict.fromkeys(r["subject"] for r in rows))
    today = datetime.now().astimezone().date()
    days = [today - timedelta(days=i) for i in range(DAYS - 1, -1, -1)]

    per_day = defaultdict(lambda: defaultdict(float))     # day -> subject -> minutes
    per_subject = defaultdict(lambda: {"min": 0.0, "done": 0, "stopped": 0})
    for r in rows:
        per_day[r["start"].date()][r["subject"]] += r["actual"]   # a session counts on the day it started
        s = per_subject[r["subject"]]
        s["min"] += r["actual"]
        if r["done"]:
            s["done"] += 1
        elif r["actual"] >= QUICK_MIN:
            s["stopped"] += 1

    real = [r for r in rows if r["done"] or r["actual"] >= QUICK_MIN]
    done = sum(r["done"] for r in rows)
    return {
        "subjects": subjects,
        "days": [{"label": d.strftime("%d %b"), "weekday": d.strftime("%a"),
                  "values": {s: round(per_day[d][s], 1) for s in subjects}} for d in days],
        "bySubject": [{"subject": s, **{k: (round(v, 1) if k == "min" else v) for k, v in per_subject[s].items()}}
                      for s in sorted(subjects, key=lambda s: -per_subject[s]["min"])],
        "totals": {
            "minutes": round(sum(r["actual"] for r in rows), 1),
            "today": round(sum(per_day[today].values()), 1),
            "done": done,
            "attempts": len(real),
            "quick": len(rows) - len(real),
        },
        "sessions": [{"subject": r["subject"], "date": r["start"].strftime("%d %b"),
                      "start": r["start"].strftime("%H:%M"), "end": r["end"].strftime("%H:%M"),
                      "planned": r["planned"], "actual": r["actual"], "done": r["done"]}
                     for r in sorted(rows, key=lambda r: r["start"], reverse=True)],
        "generated": datetime.now().strftime("%d %b %Y, %H:%M"),
    }


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Study Report</title>
<style>
:root{--bg:#f6f6f3;--card:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#8a8984;--grid:#e6e5e0;--gap:#fcfcfb;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--s5:#e87ba4;--s6:#008300;--s7:#6250d6;--s8:#e34948;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#111110;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#8d8c84;--grid:#2c2c2a;--gap:#1a1a19;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#0ca30c;--s7:#9085e9;--s8:#e66767;color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
padding:28px max(16px,env(safe-area-inset-left)) 48px}
main{max-width:980px;margin:0 auto;display:grid;gap:18px}
h1{font:600 24px/1.2 -apple-system,"SF Pro Rounded",system-ui;margin:0}
.sub{color:var(--ink2);margin:4px 0 0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--grid);border-radius:14px;padding:16px 18px;min-width:0}
.tile .k{color:var(--ink2);font-size:12px;letter-spacing:.04em;text-transform:uppercase}
.tile .v{font:600 30px/1.1 -apple-system,"SF Pro Rounded",system-ui;margin-top:6px;font-variant-numeric:tabular-nums}
.tile .n{color:var(--muted);font-size:12px;margin-top:4px}
h2{font-size:15px;margin:0 0 2px}.cap{color:var(--ink2);font-size:12.5px;margin:0 0 12px}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:12.5px;color:var(--ink2);margin-bottom:8px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
svg{display:block;width:100%;height:auto;overflow:visible}
svg text{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
.tip{position:fixed;pointer-events:none;background:var(--card);color:var(--ink);border:1px solid var(--grid);border-radius:9px;
padding:8px 10px;font-size:12.5px;box-shadow:0 6px 20px rgba(0,0,0,.18);opacity:0;transition:opacity .1s;z-index:9;min-width:140px}
.tip b{display:block;margin-bottom:3px}.tip .row{display:flex;justify-content:space-between;gap:14px;color:var(--ink2)}
.hit{fill:transparent;cursor:default}.hit:hover+g rect,.bar:hover{filter:brightness(1.12)}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--grid);white-space:nowrap}th{color:var(--ink2);font-weight:500}
td.num,th.num{text-align:right}.ok{color:var(--ink)}.no{color:var(--muted)}
.sw{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:7px}
details summary{cursor:pointer;color:var(--ink2)}
</style></head><body><main>
<header><h1>Study Report</h1><p class="sub" id="sub"></p></header>
<section class="tiles" id="tiles"></section>
<section class="card"><h2>Focus minutes per day</h2><p class="cap">Last 14 days, stacked by subject. A session counts on the day it started.</p>
<div class="legend" id="legend"></div><svg id="daily"></svg></section>
<section class="card"><h2>Time by subject</h2><p class="cap">All time. Pomodoros finished, and real attempts stopped early (taps under 1 minute are left out).</p>
<svg id="subj"></svg></section>
<section class="card"><details><summary>All sessions (table)</summary><div class="tw"><table id="tbl"></table></div></details></section>
</main><div class="tip" id="tip"></div>
<script>
const D = __DATA__;
const NS = "http://www.w3.org/2000/svg";
const color = s => `var(--s${(D.subjects.indexOf(s) % 8) + 1})`;
const fmt = m => { m = Math.round(m); return m >= 60 ? `${Math.floor(m/60)}h` + (m % 60 ? ` ${m % 60}m` : "") : `${m}m`; };
const el = (tag, attrs, parent) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); parent && parent.appendChild(e); return e; };
const tip = document.getElementById("tip");
function showTip(ev, html){ tip.innerHTML = html; tip.style.opacity = 1;
  const x = Math.min(ev.clientX + 14, innerWidth - tip.offsetWidth - 8), y = Math.min(ev.clientY + 14, innerHeight - tip.offsetHeight - 8);
  tip.style.left = x + "px"; tip.style.top = y + "px"; }
const hideTip = () => tip.style.opacity = 0;
const esc = s => s.replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

const T = D.totals;
document.getElementById("sub").textContent = `${D.subjects.length} subjects · generated ${D.generated}`;
const rate = T.attempts ? Math.round(100 * T.done / T.attempts) : 0;
document.getElementById("tiles").innerHTML = [
  ["Total focus", fmt(T.minutes), "all sessions, all time"],
  ["Today", fmt(T.today), "minutes studied today"],
  ["Pomodoros done", T.done, `out of ${T.attempts} real attempts`],
  ["Finish rate", rate + "%", `${T.quick} quick taps not counted`],
].map(([k,v,n]) => `<div class="card tile"><div class="k">${k}</div><div class="v">${v}</div><div class="n">${n}</div></div>`).join("");

document.getElementById("legend").innerHTML = D.subjects.map(s => `<span><i style="background:${color(s)}"></i>${esc(s)}</span>`).join("");

// Daily stacked bars
(() => {
  const svg = document.getElementById("daily"), W = 900, H = 260, L = 44, R = 8, Tp = 10, B = 34;
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  const totals = D.days.map(d => Object.values(d.values).reduce((a,b) => a+b, 0));
  const need = Math.max(20, ...totals) / 4, step = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240].find(v => v >= need) || 300;
  const max = step * 4, y = v => Tp + (H - Tp - B) * (1 - v / max);
  for (let i = 0; i <= 4; i++) { const v = i * step, yy = y(v);
    el("line", {x1: L, x2: W - R, y1: yy, y2: yy, stroke: "var(--grid)", "stroke-width": 1}, svg);
    el("text", {x: L - 8, y: yy + 4, "text-anchor": "end"}, svg).textContent = fmt(v); }
  const slot = (W - L - R) / D.days.length, bw = Math.min(34, slot * 0.62);
  D.days.forEach((d, i) => {
    const cx = L + slot * (i + .5); let acc = 0;
    const g = el("g", {}, svg);
    D.subjects.forEach(s => { const v = d.values[s]; if (!v) return;
      const y0 = y(acc), y1 = y(acc + v); acc += v;
      el("rect", {x: cx - bw/2, y: y1, width: bw, height: Math.max(1, y0 - y1 - 2), rx: 3, fill: color(s), class: "bar"}, g); });
    el("text", {x: cx, y: H - 18, "text-anchor": "middle"}, svg).textContent = d.label;
    el("text", {x: cx, y: H - 4, "text-anchor": "middle"}, svg).textContent = d.weekday;
    const hit = el("rect", {x: L + slot * i, y: Tp, width: slot, height: H - Tp - B, class: "hit"}, svg);
    const rows = D.subjects.filter(s => d.values[s]).map(s => `<div class="row"><span><span class="sw" style="background:${color(s)}"></span>${esc(s)}</span><span>${fmt(d.values[s])}</span></div>`).join("");
    hit.addEventListener("mousemove", ev => showTip(ev, `<b>${d.weekday} ${d.label} · ${fmt(totals[i])}</b>${rows || '<div class="row">No study</div>'}`));
    hit.addEventListener("mouseleave", hideTip);
  });
})();

// Subject bars (horizontal), direct-labelled
(() => {
  const svg = document.getElementById("subj"), rows = D.bySubject, rh = 34, W = 900, L = 170, R = 150;
  const H = rows.length * rh + 6; svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  const max = Math.max(1, ...rows.map(r => r.min)), x = v => (W - L - R) * v / max;
  rows.forEach((r, i) => { const yy = i * rh + 6;
    const name = el("text", {x: L - 12, y: yy + 16, "text-anchor": "end"}, svg); name.textContent = r.subject; name.style.fill = "var(--ink)";
    const bar = el("rect", {x: L, y: yy + 4, width: Math.max(3, x(r.min)), height: 18, rx: 4, fill: color(r.subject), class: "bar"}, svg);
    el("text", {x: L + Math.max(3, x(r.min)) + 8, y: yy + 17}, svg).textContent = `${fmt(r.min)} · ${r.done} done${r.stopped ? ` · ${r.stopped} stopped` : ""}`;
    bar.addEventListener("mousemove", ev => showTip(ev, `<b>${esc(r.subject)}</b><div class="row"><span>Focus time</span><span>${fmt(r.min)}</span></div><div class="row"><span>Pomodoros done</span><span>${r.done}</span></div><div class="row"><span>Stopped early</span><span>${r.stopped}</span></div>`));
    bar.addEventListener("mouseleave", hideTip);
  });
})();

document.getElementById("tbl").innerHTML = `<tr><th>Date</th><th>Time</th><th>Subject</th><th class="num">Planned</th><th class="num">Actual</th><th>Result</th></tr>` +
  D.sessions.map(s => `<tr><td>${s.date}</td><td>${s.start}–${s.end}</td><td><span class="sw" style="background:${color(s.subject)}"></span>${esc(s.subject)}</td><td class="num">${s.planned}m</td><td class="num">${s.actual}m</td><td class="${s.done ? "ok" : "no"}">${s.done ? "Done" : (s.actual < 1 ? "Quick tap" : "Stopped")}</td></tr>`).join("");
</script></body></html>"""


def main():
    if not CSV_PATH.exists():
        sys.exit(f"No sessions yet: {CSV_PATH} not found. Study one pomodoro first.")
    data = summarise(load())
    OUT_PATH.write_text(PAGE.replace("__DATA__", json.dumps(data)))
    print(f"Wrote {OUT_PATH.relative_to(ROOT)}  ({len(data['sessions'])} sessions, {data['totals']['done']} pomodoros done)")
    if "--no-open" not in sys.argv:
        subprocess.run(["open", str(OUT_PATH)])


if __name__ == "__main__":
    main()
