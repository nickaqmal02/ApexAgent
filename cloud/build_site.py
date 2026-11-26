#!/usr/bin/env python3
"""Builds the one public report page (cloud/site/app/index.html) from the same template the Mac uses.

The template's main script expects `const D = __DATA__;`. On the web there is no data at build time,
so the main script is parked as text, and a small loader fetches /data/<id>.json for the id in the
address, then runs it. A missing or stopped link shows "This link is not active".
Run by the CDK app before every synth/deploy; safe to run by hand.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "scripts" / "study_report_template.html"
OUT = Path(__file__).resolve().parent / "site" / "app" / "index.html"

LOADER = """<script>
(async () => {
  const id = location.pathname.split("/").filter(Boolean).pop() || "";
  let data = null;
  if (/^[A-Za-z0-9]{12}$/.test(id)) {
    try { const r = await fetch(`/data/${id}.json`, {cache: "no-cache"}); if (r.ok) data = await r.json(); } catch (_) {}
  }
  if (!data) {
    document.title = "Link not active";
    document.body.innerHTML = '<div class="wrap" style="padding-top:18vh;text-align:center"><h1>This link is not active</h1>'
      + '<p class="foot">The owner stopped sharing, or the link is mistyped.</p></div>';
    return;
  }
  window.__REPORT__ = data;
  const s = document.createElement("script");
  s.textContent = document.getElementById("report-main").textContent;
  document.body.appendChild(s);
})();
</script>"""


def build():
    html = SRC.read_text()
    marker = "<script>\nconst D = __DATA__;"
    assert html.count(marker) == 1, "template changed: update cloud/build_site.py"
    html = html.replace(marker, '<script type="text/plain" id="report-main">\nconst D = window.__REPORT__;')
    end = html.rindex("</script>")
    html = html[:end + len("</script>")] + "\n" + LOADER + html[end + len("</script>"):]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html)
    return OUT


if __name__ == "__main__":
    print(f"wrote {build().relative_to(ROOT)}")
