#!/usr/bin/env python3
"""Gane & Sarson DFD of the v1 report-sharing design (device key, JSON-only uploads).

Reuses the shape engine in docs/diagrams/setup/gen_notch_dfd.py so every DFD in the repo shares one spec.
Writes docs/architecture/share-v1-gane-sarson.drawio and .svg; prints the layout checks.
Run: python3 docs/architecture/setup/gen_share_dfd.py
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "diagrams", "setup"))
import gen_notch_dfd as g

g.OUT = os.path.dirname(HERE)   # docs/architecture/
d = g.D()
d.ent("entity_student", "Student", 60, 420)                       # 60..210 x 420..540
d.ent("entity_report_viewer", "Report\nViewer", 2000, 640)        # 2000..2150 x 640..760
d.proc("proc_1_build_report_data", "1", "Build Report\nData", 440, 60)
d.proc("proc_2_manage_share_link", "2", "Manage\nShare Link", 440, 420)
d.proc("proc_3_accept_upload", "3", "Accept\nUpload", 1000, 60)
d.proc("proc_4_serve_report_page", "4", "Serve Report\nPage", 1700, 620)
d.store("store_d1_activities", "D1", "Activities", 60, 110)
d.store("store_d2_study_sessions", "D2", "Study Sessions", 60, 190)
d.store("store_d3_upload_secret", "D3", "Upload Secret", 790, 470)
d.store("store_d4_share_keys", "D4", "Share Keys", 790, 550)
d.store("store_d5_report_data", "D5", "Report Data", 1300, 700)
d.store("store_d6_report_template", "D6", "Report Template", 1700, 480)
st, rv = "entity_student", "entity_report_viewer"
P1, P2, P3, P4 = list(d.P)
D1, D2, D3, D4, D5, D6 = list(d.ST)

d.flow(D1, P1, "Activity list", [(280, 110), (440, 110)], (360, 110, "above"))
d.flow(D2, P1, "Session history", [(280, 190), (440, 190)], (360, 190, "above"))
d.flow(P1, P3, "Report data", [(610, 145), (1000, 145)], (805, 145, "above"))
d.flow(st, P2, "Share request", [(210, 460), (440, 460)], (325, 460, "above"))
d.flow(P2, st, "Share link", [(440, 520), (210, 520)], (325, 520, "above"))
d.flow(P2, D3, "Upload secret", [(610, 470), (790, 470)], (700, 470, "above"))
d.flow(P2, D4, "Share key record", [(610, 550), (790, 550)], (700, 550, "below"))
d.flow(D3, P3, "Upload secret", [(1010, 470), (1040, 470), (1040, 230)], (1040, 350, "left"))
d.flow(D4, P3, "Share key record", [(1010, 550), (1120, 550), (1120, 230)], (1120, 390, "right"))
d.flow(P3, D5, "Report data", [(1170, 145), (1400, 145), (1400, 682)], (1400, 420, "right"))
d.flow(P2, D5, "Removal notice", [(525, 590), (525, 700), (1300, 700)], (900, 700, "above"))
d.flow(D5, P4, "Stored report data", [(1520, 700), (1700, 700)], (1610, 700, "above"))
d.flow(D6, P4, "Report template", [(1760, 498), (1760, 620)], (1760, 559, "right"))
d.flow(rv, P4, "Share link", [(2000, 670), (1870, 670)], (1935, 670, "above"))
d.flow(P4, rv, "Report page", [(1870, 730), (2000, 730)], (1935, 730, "above"))
d.X.append(dict(id="title", text="DFD: sharing a habit report, v1 (device key, JSON-only uploads)", x=60, y=-40))

if __name__ == "__main__":
    hoops, bad = g.check(d)
    s = g.build(d, "share-v1-gane-sarson", "Share v1 DFD")
    print(f"scale {s:.3f}, font {g.FS*s*1190.6/2339:.1f} pt on A3 landscape, entities {len(d.E)}, processes {len(d.P)}, "
          f"stores {len(d.ST)}, flows {len(d.F)}, hoops {len(hoops)} {hoops}")
    if bad: print("PROBLEMS:", bad); sys.exit(1)
