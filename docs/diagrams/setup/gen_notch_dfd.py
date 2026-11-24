#!/usr/bin/env python3
"""Gane & Sarson DFDs for the ApexAgent study notch as a multi-user app with AWS-hosted reports.

Writes, next to this folder (docs/diagrams/):
  notch-context-gane-sarson.drawio/.svg   Context diagram (process 0)
  notch-level1-gane-sarson.drawio/.svg    Level 1 (explosion of process 0 into 1-5)
Run: python3 docs/diagrams/setup/gen_notch_dfd.py   (prints the layout checks)

Shapes follow ~/.claude/skills/gane-sarson-dfd/SKILL.md: uniform rounded-square processes with the number
centred above a divider, 1.25:1 entities with thick top and left edges, open-ended stores with a D# box,
single-headed noun-labelled orthogonal flows, each entity once, hoops where flows cross.
Every flow has hand-placed waypoints and a hand-placed label so the checks below can prove the layout.
"""
import math, os, re, sys
from xml.sax.saxutils import escape

OUT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FS = 16.0          # font size in design units (page is A3 landscape at 2339 units wide)
S, HDR, ARC = 170, 28, 14
EW, EH = 150, 120
SW, SH, IDW = 220, 36, 40


def tw(t, fs=FS, bold=False):
    w = 0
    for ch in t:
        if ch in "il.,'tfjI1 :;|": w += 0.28
        elif ch in "mwMW": w += 0.85
        elif ch.isupper(): w += 0.68
        elif ch.isdigit(): w += 0.56
        else: w += 0.53
    return w * fs * (1.07 if bold else 1.0)


class D:
    def __init__(self):
        self.P, self.E, self.ST, self.F, self.X = {}, {}, {}, [], []

    def proc(self, id_, num, name, x, y): self.P[id_] = dict(id=id_, num=num, name=name, x=x, y=y, w=S, h=S)
    def ent(self, id_, name, x, y): self.E[id_] = dict(id=id_, name=name, x=x, y=y, w=EW, h=EH)
    def store(self, id_, did, name, x, cy): self.ST[id_] = dict(id=id_, did=did, name=name, x=x, y=cy - SH / 2, w=SW, h=SH)

    def flow(self, src, dst, label, pts, lab):
        """lab = (cx, y, where): where 'above'/'below' a horizontal line at y, or 'left'/'right' of a vertical at x=cx."""
        self.F.append(dict(n=len(self.F) + 1, src=src, dst=dst, label=label, pts=pts, lab=lab))

    def shapes(self): return {**self.P, **self.E, **self.ST}


def label_box(f):
    cx, y, where = f["lab"]
    w, h = tw(f["label"]), 1.2 * FS
    if where == "above": return (cx - w / 2, y - 3 - h, cx + w / 2, y - 3)
    if where == "below": return (cx - w / 2, y + 3, cx + w / 2, y + 3 + h)
    if where == "left": return (cx - 7 - w, y - h / 2, cx - 7, y + h / 2)
    return (cx + 7, y - h / 2, cx + 7 + w, y + h / 2)


def segs(p): return list(zip(p[:-1], p[1:]))


def cross(a, b, c, d):
    (x1, y1), (x2, y2), (x3, y3), (x4, y4) = a, b, c, d
    if y1 == y2 and x3 == x4 and min(x1, x2) < x3 < max(x1, x2) and min(y3, y4) < y1 < max(y3, y4): return (x3, y1)
    if x1 == x2 and y3 == y4 and min(y1, y2) < y3 < max(y1, y2) and min(x3, x4) < x1 < max(x3, x4): return (x1, y3)
    return None


def check(d):
    sh = d.shapes(); bad = []
    boxes = [(k, v["x"], v["y"], v["x"] + v["w"], v["y"] + v["h"]) for k, v in sh.items()]
    hoops = []
    for j, g in enumerate(d.F):
        for f in d.F[:j]:
            for a in segs(g["pts"]):
                for b in segs(f["pts"]):
                    p = cross(a[0], a[1], b[0], b[1])
                    if p: hoops.append((g["n"], f["n"], p))
    for f in d.F:
        # endpoints must sit on their own shapes' borders
        for pt, sid in ((f["pts"][0], f["src"]), (f["pts"][-1], f["dst"])):
            s = sh[sid]
            onx = s["x"] - 0.5 <= pt[0] <= s["x"] + s["w"] + 0.5 and pt[1] in (s["y"], s["y"] + s["h"])
            ony = s["y"] - 0.5 <= pt[1] <= s["y"] + s["h"] + 0.5 and pt[0] in (s["x"], s["x"] + s["w"])
            if not (onx or ony): bad.append(("endpoint-off-border", f["n"], sid))
            if sid in d.P and pt[0] in (s["x"], s["x"] + s["w"]) and not (s["y"] + HDR + 6 <= pt[1] <= s["y"] + s["h"] - ARC):
                bad.append(("lane-outside-process-body", f["n"], sid))
        for a, b in segs(f["pts"]):
            if a[0] != b[0] and a[1] != b[1]: bad.append(("diagonal-segment", f["n"]))
            sx1, sx2 = sorted([a[0], b[0]]); sy1, sy2 = sorted([a[1], b[1]])
            for k, x1, y1, x2, y2 in boxes:
                if sx2 > x1 + 1 and sx1 < x2 - 1 and sy2 > y1 + 1 and sy1 < y2 - 1: bad.append(("flow-through-shape", f["n"], k))
    labs = [(f["n"], label_box(f)) for f in d.F]
    for i, (n, r) in enumerate(labs):
        for m, q in labs[i + 1:]:
            if r[2] > q[0] and q[2] > r[0] and r[3] > q[1] and q[3] > r[1]: bad.append(("label-label", n, m))
        for k, x1, y1, x2, y2 in boxes:
            if r[2] > x1 and x2 > r[0] and r[3] > y1 and y2 > r[1]: bad.append(("label-shape", n, k))
        for f in d.F:
            for a, b in segs(f["pts"]):
                sx1, sx2 = sorted([a[0], b[0]]); sy1, sy2 = sorted([a[1], b[1]])
                if sx2 > r[0] + 0.5 and sx1 < r[2] - 0.5 and sy2 > r[1] + 0.5 and sy1 < r[3] - 0.5: bad.append(("label-flow", n, f["n"]))
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            if a[3] > b[1] and b[3] > a[1] and a[4] > b[2] and b[4] > a[2]: bad.append(("shape-shape", a[0], b[0]))
    return hoops, bad


def fmt(v): return ("%.2f" % v).rstrip("0").rstrip(".")
def xesc(t): return escape(t, {'"': "&quot;"}).replace("\n", "&#10;")
def slug(t): return re.sub(r"[^a-z0-9]+", "_", t.lower()).strip("_")


def build(d, name, diagram_name, pageW=2339, pageH=1654, margin=40):
    xs, ys = [], []
    for v in d.shapes().values(): xs += [v["x"], v["x"] + v["w"]]; ys += [v["y"], v["y"] + v["h"]]
    for f in d.F:
        for x, y in f["pts"]: xs.append(x); ys.append(y)
        r = label_box(f); xs += [r[0], r[2]]; ys += [r[1], r[3]]
    for t in d.X: xs += [t["x"], t["x"] + tw(t["text"], bold=True)]; ys += [t["y"], t["y"] + 20]
    bx0, by0, bx1, by1 = min(xs), min(ys), max(xs), max(ys)
    s = min((pageW - 2 * margin) / (bx1 - bx0), (pageH - 2 * margin) / (by1 - by0), 1.0)
    ox = (pageW - s * (bx1 - bx0)) / 2 - s * bx0; oy = (pageH - s * (by1 - by0)) / 2 - s * by0
    X = lambda v: ox + s * v; Y = lambda v: oy + s * v
    fs, sw, swf = FS * s, 2.0, 1.5
    cells, svg = [], ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Arial, Helvetica, sans-serif"><rect width="%d" height="%d" fill="#fff"/>' % ((pageW, pageH) * 3)]
    TS = "text;html=0;strokeColor=none;fillColor=none;fontColor=#000000;fontSize=%s;fontFamily=Arial;%salign=%s;verticalAlign=middle;spacing=0;whiteSpace=nowrap;"

    def vcell(id_, value, style, x, y, w, h):
        cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1"><mxGeometry x="%s" y="%s" width="%s" height="%s" as="geometry"/></mxCell>' % (id_, xesc(value), style, fmt(x), fmt(y), fmt(w), fmt(h)))

    def line(id_, x1, y1, x2, y2, wd=sw):
        cells.append('<mxCell id="%s" value="" style="endArrow=none;html=0;strokeColor=#000000;strokeWidth=%s;" edge="1" parent="1"><mxGeometry relative="1" as="geometry"><mxPoint x="%s" y="%s" as="sourcePoint"/><mxPoint x="%s" y="%s" as="targetPoint"/></mxGeometry></mxCell>' % (id_, fmt(wd), fmt(x1), fmt(y1), fmt(x2), fmt(y2)))
        svg.append('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="#000" stroke-width="%s"/>' % (x1, y1, x2, y2, fmt(wd)))

    def text(lines, cx, cy, size, bold, anchor="middle"):
        lh = 1.2 * size; first = cy - (len(lines) - 1) * lh / 2 + 0.35 * size
        for i, t in enumerate(lines):
            svg.append('<text x="%.2f" y="%.2f" font-size="%s"%s text-anchor="%s">%s</text>' % (cx, first + i * lh, fmt(size), ' font-weight="bold"' if bold else "", anchor, escape(t)))

    for p in d.P.values():
        x, y, w, h = X(p["x"]), Y(p["y"]), p["w"] * s, p["h"] * s
        vcell(p["id"], "", "rounded=1;absoluteArcSize=1;arcSize=%s;whiteSpace=wrap;html=0;strokeColor=#000000;strokeWidth=%s;fillColor=#FFFFFF;" % (fmt(ARC * s), fmt(sw)), x, y, w, h)
        svg.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="#fff" stroke="#000" stroke-width="%s"/>' % (x, y, w, h, ARC * s, fmt(sw)))
        hd = HDR * s
        line(p["id"] + "_divider", x, y + hd, x + w, y + hd)
        vcell(p["id"] + "_number", p["num"], TS % (fmt(fs * 1.05), "fontStyle=1;", "center"), x, y, w, hd)
        text([p["num"]], x + w / 2, y + hd / 2, fs * 1.05, True)
        vcell(p["id"] + "_name", p["name"], TS % (fmt(fs), "fontStyle=1;", "center"), x + 6 * s, y + hd, w - 12 * s, h - hd)
        text(p["name"].split("\n"), x + w / 2, y + hd + (h - hd) / 2, fs, True)
    for e in d.E.values():
        x, y, w, h = X(e["x"]), Y(e["y"]), e["w"] * s, e["h"] * s
        vcell(e["id"], "", "rounded=0;html=0;strokeColor=#000000;strokeWidth=%s;fillColor=#FFFFFF;" % fmt(sw), x, y, w, h)
        svg.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#fff" stroke="#000" stroke-width="%s"/>' % (x, y, w, h, fmt(sw)))
        tk = sw * 2.5
        line(e["id"] + "_thick_top", x - sw / 2, y + tk / 2 - sw / 2, x + w + sw / 2, y + tk / 2 - sw / 2, tk)
        line(e["id"] + "_thick_left", x + tk / 2 - sw / 2, y, x + tk / 2 - sw / 2, y + h, tk)
        vcell(e["id"] + "_name", e["name"], TS % (fmt(fs), "fontStyle=1;", "center"), x + 6 * s, y + 6 * s, w - 12 * s, h - 12 * s)
        text(e["name"].split("\n"), x + w / 2, y + h / 2, fs, True)
    for st in d.ST.values():
        x, y, w, h = X(st["x"]), Y(st["y"]), st["w"] * s, st["h"] * s
        vcell(st["id"], "", "shape=partialRectangle;right=0;fillColor=#FFFFFF;strokeColor=#000000;strokeWidth=%s;html=0;" % fmt(sw), x, y, w, h)
        svg.append('<path d="M%.2f,%.2f L%.2f,%.2f L%.2f,%.2f L%.2f,%.2f" fill="#fff" stroke="#000" stroke-width="%s"/>' % (x + w, y, x, y, x, y + h, x + w, y + h, fmt(sw)))
        idw = IDW * s
        line(st["id"] + "_idsep", x + idw, y, x + idw, y + h)
        vcell(st["id"] + "_id", st["did"], TS % (fmt(fs), "fontStyle=1;", "center"), x, y, idw, h)
        text([st["did"]], x + idw / 2, y + h / 2, fs, True)
        vcell(st["id"] + "_name", st["name"], TS % (fmt(fs), "", "center"), x + idw + 2 * s, y, w - idw - 6 * s, h)
        text([st["name"]], x + idw + (w - idw) / 2, y + h / 2, fs, False)
    for t in d.X:
        vcell(t["id"], t["text"], TS % (fmt(fs), "fontStyle=1;", "left"), X(t["x"]), Y(t["y"]), tw(t["text"], bold=True) * s + 10, 20 * s)
        text([t["text"]], X(t["x"]), Y(t["y"]) + 10 * s, fs, True, "start")

    sh = d.shapes(); drawn = []; r = 7.0
    aL, aH = max(7, 11 * s), max(3.5, 4.5 * s)
    for f in d.F:
        pts = f["pts"]
        def frac(sid, pt):
            v = sh[sid]; return min(1, max(0, (pt[0] - v["x"]) / v["w"])), min(1, max(0, (pt[1] - v["y"]) / v["h"]))
        ex, ey = frac(f["src"], pts[0]); nx, ny = frac(f["dst"], pts[-1])
        style = ("edgeStyle=none;html=0;rounded=0;endArrow=block;endFill=1;strokeColor=#000000;strokeWidth=%s;jumpStyle=arc;jumpSize=10;"
                 "exitX=%.4f;exitY=%.4f;exitDx=0;exitDy=0;exitPerimeter=1;entryX=%.4f;entryY=%.4f;entryDx=0;entryDy=0;entryPerimeter=1;") % (fmt(swf), ex, ey, nx, ny)
        mid = "".join('<mxPoint x="%s" y="%s"/>' % (fmt(X(a)), fmt(Y(b))) for a, b in pts[1:-1])
        fid = "flow_%02d_%s_to_%s_%s" % (f["n"], f["src"], f["dst"], slug(f["label"]))
        cells.append('<mxCell id="%s" value="" style="%s" edge="1" parent="1" source="%s" target="%s"><mxGeometry relative="1" as="geometry">%s</mxGeometry></mxCell>'
                     % (fid, style, f["src"], f["dst"], '<Array as="points">%s</Array>' % mid if mid else ""))
        dd = ""
        for si, (a, b) in enumerate(segs(pts)):
            hits = [p for c, e in drawn for p in [cross(a, b, c, e)] if p]
            hz = a[1] == b[1]
            hits.sort(key=lambda p: abs(p[0] - a[0]) if hz else abs(p[1] - a[1]))
            if si == 0: dd += "M%.2f,%.2f" % (X(a[0]), Y(a[1]))
            for p in hits:
                if hz:
                    k = 1 if b[0] > a[0] else -1
                    dd += " L%.2f,%.2f A%.2f,%.2f 0 0 %d %.2f,%.2f" % (X(p[0] - k * r), Y(p[1]), r * s, r * s, 1 if k > 0 else 0, X(p[0] + k * r), Y(p[1]))
                else:
                    k = 1 if b[1] > a[1] else -1
                    dd += " L%.2f,%.2f A%.2f,%.2f 0 0 %d %.2f,%.2f" % (X(p[0]), Y(p[1] - k * r), r * s, r * s, 1 if k > 0 else 0, X(p[0]), Y(p[1] + k * r))
            dd += " L%.2f,%.2f" % (X(b[0]), Y(b[1]))
        svg.append('<path d="%s" fill="none" stroke="#000" stroke-width="%s"/>' % (dd, fmt(swf)))
        tip, frm = (X(pts[-1][0]), Y(pts[-1][1])), (X(pts[-2][0]), Y(pts[-2][1]))
        dx, dy = tip[0] - frm[0], tip[1] - frm[1]; n = math.hypot(dx, dy); ux, uy = dx / n, dy / n
        bx, by = tip[0] - ux * aL, tip[1] - uy * aL
        svg.append('<polygon points="%.2f,%.2f %.2f,%.2f %.2f,%.2f" fill="#000"/>' % (tip[0], tip[1], bx - uy * aH, by + ux * aH, bx + uy * aH, by - ux * aH))
        drawn += segs(pts)
        x0, y0, x1, y1 = label_box(f)
        vcell("lbl_%02d_%s" % (f["n"], slug(f["label"])), f["label"], TS % (fmt(fs), "", "center"), X(x0) - 3, Y(y0), (x1 - x0) * s + 6, (y1 - y0) * s)
        text([f["label"]], X((x0 + x1) / 2), Y((y0 + y1) / 2), fs, False)
    svg.append("</svg>")
    xml = ('<mxfile host="app.diagrams.net" agent="gen_notch_dfd.py"><diagram id="%s" name="%s"><mxGraphModel grid="0" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="%d" pageHeight="%d" background="#FFFFFF" math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>'
           % (slug(diagram_name), xesc(diagram_name), pageW, pageH) + "".join(cells) + "</root></mxGraphModel></diagram></mxfile>")
    open(os.path.join(OUT, name + ".drawio"), "w").write(xml)
    open(os.path.join(OUT, name + ".svg"), "w").write("\n".join(svg))
    return s


# ---------------- Context diagram ----------------
C = D()
C.ent("entity_student", "Student", 100, 280)                 # centre y 340
C.proc("proc_0_track_study_habits", "0", "Track Study\nHabits", 560, 255)
C.ent("entity_report_viewer", "Report\nViewer", 1000, 280)
st, p0, rv = "entity_student", "proc_0_track_study_habits", "entity_report_viewer"
C.flow(st, p0, "Activity details", [(250, 305), (560, 305)], (405, 305, "above"))
C.flow(st, p0, "Session command", [(250, 340), (560, 340)], (405, 340, "above"))
C.flow(st, p0, "Report request", [(250, 375), (560, 375)], (405, 375, "above"))
C.flow(p0, st, "Notch status", [(600, 255), (600, 200), (215, 200), (215, 280)], (407, 200, "above"))
C.flow(p0, st, "Habit report", [(690, 255), (690, 150), (165, 150), (165, 280)], (427, 150, "above"))
C.flow(st, p0, "Login details", [(165, 400), (165, 500), (690, 500), (690, 425)], (427, 500, "above"))
C.flow(p0, st, "Share link", [(600, 425), (600, 460), (215, 460), (215, 400)], (407, 460, "above"))
C.flow(rv, p0, "Share link", [(1000, 310), (730, 310)], (865, 310, "above"))
C.flow(p0, rv, "Report page", [(730, 370), (1000, 370)], (865, 370, "above"))
C.X.append(dict(id="title", text="Context diagram: study notch with AWS-hosted habit reports", x=100, y=60))

# ---------------- Level 1 ----------------
L = D()
L.ent("entity_student", "Student", 60, 500)                   # 60..210 x 500..620
L.proc("proc_1_manage_activities", "1", "Manage\nActivities", 380, 100)
L.proc("proc_2_run_study_session", "2", "Run Study\nSession", 380, 475)
L.proc("proc_3_build_habit_report", "3", "Build Habit\nReport", 950, 475)
L.proc("proc_4_publish_report", "4", "Publish\nReport", 1250, 475)
L.proc("proc_5_serve_shared_report", "5", "Serve Shared\nReport", 1920, 520)
L.store("store_d1_activities", "D1", "Activities", 700, 185)
L.store("store_d2_study_sessions", "D2", "Study Sessions", 700, 800)
L.store("store_d3_user_accounts", "D3", "User Accounts", 1560, 540)
L.store("store_d4_report_files", "D4", "Report Files", 1560, 610)
L.store("store_d5_share_links", "D5", "Share Links", 1560, 760)
L.ent("entity_report_viewer", "Report\nViewer", 2240, 560)    # 2240..2390 x 560..680
P1, P2, P3, P4, P5 = (k for k in L.P)
D1, D2, D3, D4, D5 = (k for k in L.ST)
st, rv = "entity_student", "entity_report_viewer"
L.flow(st, P1, "Activity details", [(190, 500), (190, 200), (380, 200)], (285, 200, "above"))
L.flow(st, P2, "Session command", [(210, 540), (380, 540)], (295, 540, "above"))
L.flow(P2, st, "Notch status", [(380, 590), (210, 590)], (295, 590, "above"))
L.flow(P1, D1, "Activity record", [(550, 185), (700, 185)], (625, 185, "above"))
L.flow(D1, P2, "Activity settings", [(740, 203), (740, 600), (550, 600)], (645, 600, "above"))
L.flow(D1, P3, "Activity list", [(920, 185), (990, 185), (990, 475)], (990, 330, "left"))
L.flow(P2, D2, "Session record", [(465, 645), (465, 800), (700, 800)], (582, 800, "above"))
L.flow(D2, P3, "Session history", [(920, 800), (1000, 800), (1000, 645)], (1000, 722, "left"))
L.flow(st, P3, "Report request", [(180, 620), (180, 950), (1060, 950), (1060, 645)], (620, 950, "above"))
L.flow(P3, st, "Habit report", [(1100, 475), (1100, 60), (150, 60), (150, 500)], (625, 60, "above"))
L.flow(P3, P4, "Report file", [(1120, 540), (1250, 540)], (1185, 540, "above"))
L.flow(st, P4, "Login details", [(110, 620), (110, 1010), (1300, 1010), (1300, 645)], (705, 1010, "above"))
L.flow(P4, st, "Share link", [(1335, 475), (1335, 10), (90, 10), (90, 500)], (712, 10, "above"))
L.flow(P4, D3, "New account", [(1420, 527), (1560, 527)], (1490, 527, "above"))
L.flow(D3, P4, "Account record", [(1560, 553), (1420, 553)], (1490, 553, "below"))
L.flow(P4, D4, "Report file", [(1420, 615), (1560, 615)], (1490, 615, "below"))
L.flow(P4, D5, "Share entry", [(1390, 645), (1390, 760), (1560, 760)], (1475, 760, "above"))
L.flow(D4, P5, "Stored report", [(1780, 610), (1920, 610)], (1850, 610, "above"))
L.flow(D5, P5, "Share entry", [(1780, 760), (1850, 760), (1850, 660), (1920, 660)], (1850, 712, "left"))
L.flow(rv, P5, "Share link", [(2240, 590), (2090, 590)], (2165, 590, "above"))
L.flow(P5, rv, "Report page", [(2090, 650), (2240, 650)], (2165, 650, "above"))
L.X.append(dict(id="title", text="DFD Level 1: explosion of process 0 \"Track Study Habits\" (1-5)", x=60, y=-60))

if __name__ == "__main__":
    ok = True
    for nm, dg, title in (("notch-context-gane-sarson", C, "Context diagram"), ("notch-level1-gane-sarson", L, "DFD Level 1")):
        hoops, bad = check(dg)
        s = build(dg, nm, title)
        print(f"{nm}: scale {s:.3f}, font {FS*s:.1f} units = {FS*s*1190.6/2339:.1f} pt on A3 landscape, "
              f"entities {len(dg.E)}, processes {len(dg.P)}, stores {len(dg.ST)}, flows {len(dg.F)}, hoops {len(hoops)} {hoops}")
        if bad: ok = False; print("  PROBLEMS:", bad)
    sys.exit(0 if ok else 1)
