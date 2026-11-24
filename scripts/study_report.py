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
DAILY_GOAL_MIN = float(os.environ.get("STUDY_GOAL_MIN", 100))   # the academic ring: 4 pomodoros a day
SUBJECTS_PATH = ROOT / "data" / "subjects.json"

# Same keys and order as StudyCategory in StudyNotch.swift. Each gets its own ring and daily goal
# (override with STUDY_GOAL_HEALTH=45 and so on; academic keeps STUDY_GOAL_MIN).
CATEGORIES = [
    ("academic", "Academic", DAILY_GOAL_MIN),
    ("health", "Health", float(os.environ.get("STUDY_GOAL_HEALTH", 30))),
    ("soul", "Soul", float(os.environ.get("STUDY_GOAL_SOUL", 25))),
    ("personal", "Personal", float(os.environ.get("STUDY_GOAL_PERSONAL", 30))),
]
CATEGORIES_PATH = ROOT / "data" / "categories.json"


def custom_categories():
    """The user's own categories from the notch (data/categories.json): key, label, icon, color. [] if none."""
    try:
        return [c for c in json.loads(CATEGORIES_PATH.read_text()) if isinstance(c, dict) and c.get("key")]
    except (OSError, ValueError, TypeError):
        return []


CUSTOM = custom_categories()
# Custom categories come after the four built-in ones, like the notch tabs. Their daily goal defaults
# to 30 min (STUDY_GOAL_DEFAULT changes it for all of them).
CATEGORIES += [(c["key"], c.get("label") or c["key"], float(os.environ.get("STUDY_GOAL_DEFAULT", 30))) for c in CUSTOM]
CAT_KEYS = [k for k, _, _ in CATEGORIES]
CAT_COLOR = {c["key"]: c.get("color", "#8e8e93") for c in CUSTOM}   # built-in colours live in the template


def subject_list():
    """The notch's activity list (data/subjects.json): name, minutes, category. Empty if missing or unreadable."""
    try:
        return [s for s in json.loads(SUBJECTS_PATH.read_text()) if isinstance(s, dict) and "name" in s]
    except (OSError, ValueError, TypeError):
        return []


def subject_categories():
    """name -> category from the notch's activity list, for rows written before the CSV had the column."""
    return {s["name"]: s.get("category", "academic") for s in subject_list()}


# One card per activity in every category except academic, which gets one combined Study card
HABIT_CATS = set(CAT_KEYS) - {"academic"}


def week_of(today):
    """Monday to Sunday of the current week (days after today are shown as upcoming)."""
    monday = today - timedelta(days=today.weekday())
    return [monday + timedelta(days=i) for i in range(7)]


def habit_card(name, category, mine, today, target, options=(), studied_counts=False, needs_all=True):
    """One habit: its days this week, today's progress against the target, and its streak.
    Normal habit: a day is done when one session finished; started-but-stopped is partial.
    With options (Pray): done when every option finished that day; some of them is partial.
    studied_counts (the Study card): any real study that day (1 min or more) fills the dot."""
    mins, finished = defaultdict(float), defaultdict(set)   # day -> minutes, day -> options finished
    for r in mine:
        d = r["start"].date()
        mins[d] += r["actual"]
        if r["done"]:
            finished[d].add(r["detail"])
    if options and not needs_all:   # sunnah prayers: any one of them done counts the day
        done = {d for d, got in finished.items() if got & set(options)}
        partial = {d for d, m in mins.items() if m >= QUICK_MIN} - done
    elif options:
        done = {d for d, got in finished.items() if set(options) <= got}
        partial = {d for d, got in finished.items() if got & set(options)} - done
    elif studied_counts:
        done = {d for d, m in mins.items() if m >= QUICK_MIN} | set(finished)
        partial = set()
    else:
        done = set(finished)
        partial = {d for d, m in mins.items() if m >= QUICK_MIN} - done
    streak, d = 0, today if today in done else today - timedelta(days=1)
    while d in done:
        streak, d = streak + 1, d - timedelta(days=1)
    week = week_of(today)
    prev = [x - timedelta(days=7) for x in week]   # last week, for cards that get a full-width row

    def day(x):
        return {"wd": x.strftime("%a"), "d": x.strftime("%a %d %b"), "m": round(mins[x], 1),
                "n": len(finished[x] & set(options)) if options else None,
                "future": x > today, "today": x == today,
                "s": 2 if x in done else (1 if x in partial else 0)}
    return {
        "name": name,
        "category": category,
        "target": float(target),
        "today": round(mins[today], 1),
        "streak": streak,
        "weekDone": sum(1 for x in week if x in done),
        "weekMin": round(sum(mins[x] for x in week), 1),
        "options": list(options),
        "needsAll": needs_all,
        "todayOptions": [o for o in options if o in finished[today]],
        "days": [day(x) for x in week],
        "prevDays": [day(x) for x in prev],
        "prevDone": sum(1 for x in prev if x in done),
        "prevMin": round(sum(mins[x] for x in prev), 1),
        "_done": done,   # every done day, for the big all-habits grid; removed before the JSON is written
    }


def habits(rows, today):
    """Study first (all academic subjects together, target = the daily study goal), then one card per
    Health / Soul / Personal activity: every one in the notch list, plus old names used this week."""
    week_start = week_of(today)[0]
    listed = subject_list()
    info = {s["name"]: s for s in listed}
    out = [habit_card("Study", "academic", [r for r in rows if r["category"] == "academic"], today,
                      DAILY_GOAL_MIN, studied_counts=True)]
    names = [s["name"] for s in listed]
    names += sorted({r["subject"] for r in rows if r["start"].date() >= week_start} - set(names))
    cards = []
    for name in names:
        mine = [r for r in rows if r["subject"] == name]
        latest = max(mine, key=lambda r: r["start"]) if mine else None
        cat = info.get(name, {}).get("category") or (latest["category"] if latest else "academic")
        if cat not in HABIT_CATS:
            continue
        if info.get(name, {}).get("isHabit", True) is False:
            continue   # time only (toilet, coffee): counted in Summary, Activities and Sessions, not a habit
        target = info.get(name, {}).get("minutes") or (latest["planned"] if latest else 25)
        entry = info.get(name, {})
        needs_all = entry.get("needsAll", name.lower() not in {"sunnah", "sunat", "solat sunat", "sunnah prayer", "nawafil"})
        cards.append(habit_card(name, cat, mine, today, target, entry.get("options") or [], needs_all=needs_all))
    order = {k: i for i, k in enumerate(CAT_KEYS)}
    return out + sorted(cards, key=lambda h: order[h["category"]])   # stable: keeps list order inside a category


HEAT_WEEKS = 26   # the big grid on top of Habits: about six months, one column per week


def habit_heat(cards, today):
    """The big all-habits grid: for every day of the last HEAT_WEEKS weeks (Monday to Sunday columns),
    how many of today's habits were done. A day where all of them were done is a perfect day.
    Also pops the private _done sets off the cards so the rest can go to JSON."""
    done_sets = [c.pop("_done") for c in cards]
    total = len(done_sets)
    end = week_of(today)[-1]
    days = [end - timedelta(days=i) for i in range(HEAT_WEEKS * 7 - 1, -1, -1)]
    counts = {d: sum(d in s for s in done_sets) for d in days if d <= today}
    perfect = {d for d, n in counts.items() if total and n == total}
    streak, d = 0, today if today in perfect else today - timedelta(days=1)
    while d in perfect:
        streak, d = streak + 1, d - timedelta(days=1)
    best = run = 0
    for d in days:
        run = run + 1 if d in perfect else 0
        best = max(best, run)
    return {
        "total": total,
        "perfect": len(perfect),
        "streak": streak,
        "best": best,
        "days": [{"d": d.strftime("%a %d %b"), "m": d.strftime("%b"), "first": d.day <= 7 and d.weekday() == 0,
                  "n": counts.get(d), "today": d == today} for d in days],   # n is None for days still to come
    }


def day_group(d, today):
    """Heading for the sessions list: Today, Yesterday, or 'Wed 18 Nov'."""
    if d == today:
        return "Today"
    if d == today - timedelta(days=1):
        return "Yesterday"
    return d.strftime("%a %d %b")


def load():
    rows = []
    fallback = subject_categories()
    with CSV_PATH.open(newline="") as f:
        for r in csv.DictReader(f):
            start = datetime.fromisoformat(r["started_at"])
            # The row's own category wins; old 7-column rows look it up; unknown names were study
            cat = (r.get("category") or fallback.get(r["subject"]) or "academic").strip()
            rows.append({
                "subject": r["subject"],
                "category": cat if cat in CAT_KEYS else "academic",
                "detail": (r.get("detail") or "").strip(),   # which prayer, for activities with options
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
    per_day_cat = defaultdict(lambda: defaultdict(float)) # day -> category -> minutes
    per_subject = defaultdict(lambda: {"min": 0.0, "done": 0, "stopped": 0})
    subject_cat = {}                                      # the category a subject was last logged under
    for r in sorted(rows, key=lambda r: r["start"]):
        subject_cat[r["subject"]] = r["category"]
    for r in rows:
        per_day[r["start"].date()][r["subject"]] += r["actual"]   # a session counts on the day it started
        per_day_cat[r["start"].date()][r["category"]] += r["actual"]
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

    def cat_window(cat, first, last):
        return round(sum(per_day_cat[today - timedelta(days=i)][cat] for i in range(first, last + 1)), 1)

    return {
        "subjects": subjects,
        "subjectCategory": {**subject_categories(), **subject_cat},
        "habits": (cards := habits(rows, today)),
        "heat": habit_heat(cards, today),
        "categories": [{"key": k, "label": label, "goal": goal, "color": CAT_COLOR.get(k),
                        "today": round(per_day_cat[today][k], 1),
                        "week": cat_window(k, 0, 6),
                        "total": round(sum(r["actual"] for r in rows if r["category"] == k), 1),
                        "sessions": sum(1 for r in real if r["category"] == k)}
                       for k, label, goal in CATEGORIES],
        "days": [{"label": d.strftime("%d %b"), "weekday": d.strftime("%a"),
                  "values": {s: round(per_day[d][s], 1) for s in subjects},
                  "cats": {k: round(per_day_cat[d][k], 1) for k in CAT_KEYS}} for d in days],
        "bySubject": [{"subject": s, "category": subject_cat[s],
                       **{k: (round(v, 1) if k == "min" else v) for k, v in per_subject[s].items()}}
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
        "sessions": [{"subject": r["subject"], "category": r["category"], "detail": r["detail"], "date": r["start"].strftime("%d %b"), "hour": r["start"].hour,
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
