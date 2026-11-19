#!/usr/bin/env python3
"""Study report: reads data/study_sessions.csv and writes data/study_report.html.

Run from the project root:   python3 scripts/study_report.py [--upload] [--no-open]
Then it opens the report in your browser. Standard library only (no pandas/matplotlib).
The page design is in scripts/study_report_template.html (three views: overview, subjects, sessions).
The report is a local file under data/ (gitignored) because it holds your study history.
"""
import csv
import os
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
DAILY_GOAL_MIN = float(os.environ.get("STUDY_GOAL_MIN", 100))   # the ring on the summary: 4 pomodoros a day


def day_group(d, today):
    """Heading for the sessions list: Today, Yesterday, or 'Wed 18 Nov'."""
    if d == today:
        return "Today"
    if d == today - timedelta(days=1):
        return "Yesterday"
    return d.strftime("%a %d %b")


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

    # Streak: days in a row (ending today, or yesterday if nothing yet today) with real study
    studied = {r["start"].date() for r in real}
    streak, d = 0, today if today in studied else today - timedelta(days=1)
    while d in studied:
        streak, d = streak + 1, d - timedelta(days=1)

    def window(first, last):   # minutes from `first` to `last` days ago, inclusive
        return round(sum(sum(per_day[today - timedelta(days=i)].values()) for i in range(first, last + 1)), 1)

    for s in per_subject:
        mine = [r for r in real if r["subject"] == s]
        per_subject[s]["avg"] = round(sum(r["actual"] for r in mine) / len(mine), 1) if mine else 0
        per_subject[s]["last"] = max(r["start"] for r in mine).strftime("%d %b") if mine else "-"

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
            "week": window(0, 6),
            "lastWeek": window(7, 13),
            "streak": streak,
            "goal": DAILY_GOAL_MIN,
        },
        "sessions": [{"subject": r["subject"], "date": r["start"].strftime("%d %b"), "hour": r["start"].hour,
                      "group": day_group(r["start"].date(), today),
                      "start": r["start"].strftime("%H:%M"), "end": r["end"].strftime("%H:%M"),
                      "planned": r["planned"], "actual": r["actual"], "done": r["done"]}
                     for r in sorted(rows, key=lambda r: r["start"], reverse=True)],
        "generated": datetime.now().strftime("%d %b %Y, %H:%M"),
    }

def upload(path):
    bucket = os.environ.get("STUDY_BUCKET")
    dist = os.environ.get("STUDY_DIST_ID")
    url = os.environ.get("STUDY_URL")
    if not (bucket and dist and url):
        sys.exit("Set STUDY_BUCKET, STUDY_DIST_ID and STUDY_URL in ~/.zshrc first")

    subprocess.run(["aws", "s3", "cp", str(path), f"s3://{bucket}/index.html",
                    "--content-type", "text/html"], check=True)
    
    subprocess.run(["aws", "cloudfront", "create-invalidation",
                    "--distribution-id", dist, "--paths", "/index.html", "/"], check=True)
    
    print(f"Live at {url}  (give CloudFront ~30 s to refresh)")


# The page design lives in its own file so styling can change without touching the Python
TEMPLATE_PATH = Path(__file__).with_name("study_report_template.html")


def main():
    if not CSV_PATH.exists():
        sys.exit(f"No sessions yet: {CSV_PATH} not found. Study one pomodoro first.")
    data = summarise(load())
    OUT_PATH.write_text(TEMPLATE_PATH.read_text().replace("__DATA__", json.dumps(data)))
    print(f"Wrote {OUT_PATH.relative_to(ROOT)}  ({len(data['sessions'])} sessions, {data['totals']['done']} pomodoros done)")
    if "--upload" in sys.argv:
        upload(OUT_PATH)
    if "--no-open" not in sys.argv:
        subprocess.run(["open", str(OUT_PATH)])



if __name__ == "__main__":
    main()
