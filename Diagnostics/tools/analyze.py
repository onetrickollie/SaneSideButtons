#!/usr/bin/env python3
"""Summarize a SwipeRecorder run folder: what event stream reached apps
for a real trackpad swipe vs. a SaneSideButtons side-button press.

Usage: python3 -I analyze.py runs/<timestamp>
"""
import csv
import json
import sys
from collections import Counter
from pathlib import Path


CG_NAMES = {22: "scrollWheel", 25: "otherMouseDown", 26: "otherMouseUp", 27: "otherMouseDragged",
            29: "gesture", 30: "dockSwipe", 31: "swipe"}


def load(path):
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            r["ns_type"] = CG_NAMES.get(r["cg_type"], f'type{r["cg_type"]}')
            rows.append(r)
    return rows


def summarize(rows):
    kinds = Counter((r["ns_type"], r["source"]) for r in rows)
    gest = [r for r in rows if r["cg_type"] in (29, 30) or r["ns_type"] in ("swipe", "beginGesture", "endGesture", "gesture")]
    scroll_phased = [r for r in rows if r["ns_type"] == "scrollWheel" and r.get("phase", "none") != "none"]
    momentum = [r for r in rows if r["ns_type"] == "scrollWheel" and r.get("momentum_phase", "none") != "none"]
    downs = [r for r in rows if r["ns_type"] == "otherMouseDown"]
    buttons = sorted({r["int_fields"].get("3", 0) for r in rows if r["cg_type"] in (25, 26)})
    ups = [r for r in rows if r["ns_type"] == "otherMouseUp"]
    span = 0.0
    if gest:
        span = gest[-1]["t_ms"] - gest[0]["t_ms"]
    return {
        "events": len(rows),
        "gesture_events": len(gest),
        "gesture_span_ms": round(span, 1),
        "dock_swipe_type30": sum(1 for r in rows if r["cg_type"] == 30),
        "phased_scroll": len(scroll_phased),
        "momentum_scroll": len(momentum),
        "button_down_seen": len(downs),
        "button_up_seen": len(ups),
        "buttons": buttons,
        "sources": sorted({r["source"] for r in gest}),
        "kinds": kinds,
        "gest": gest,
    }


def seq(gest, limit=12):
    out = []
    for r in gest[:limit]:
        f = r.get("int_fields", {})
        out.append(f'{r["t_ms"]:.1f}ms cg{r["cg_type"]}/{r["ns_type"]} ph={r.get("phase","-")} '
                   f'f110={f.get("110","-")} f132={f.get("132","-")} f123={f.get("123","-")}')
    if len(gest) > limit:
        out.append(f"... (+{len(gest) - limit} more)")
    return out


def main():
    run = Path(sys.argv[1])
    ratings = {}
    rp = run / "ratings.csv"
    if rp.exists():
        for row in csv.DictReader(rp.open()):
            ratings[row["label"]] = row
    labels = {"1": "smooth", "2": "jumpy", "3": "nothing", "4": "funky"}
    print((run / "env.txt").read_text() if (run / "env.txt").exists() else "")
    print("| run | your rating | gesture events | span ms | type-30 swipe | phased scroll | momentum | btn down/up seen | button # | gesture source |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    details = []
    for p in sorted(run.glob("*.jsonl")):
        s = summarize(load(p))
        rt = ratings.get(p.stem, {})
        r = labels.get(rt.get("rating", ""), rt.get("rating", "-"))
        print(f'| {p.stem} | {r} | {s["gesture_events"]} | {s["gesture_span_ms"]} | {s["dock_swipe_type30"]} | '
              f'{s["phased_scroll"]} | {s["momentum_scroll"]} | {s["button_down_seen"]}/{s["button_up_seen"]} | {",".join(map(str, s["buttons"])) or "-"} | '
              f'{", ".join(s["sources"]) or "-"} |')
        details.append((p.stem, s, rt.get("notes", "")))
    for name, s, notes in details:
        print(f"\n## {name}" + (f"  (notes: {notes})" if notes else ""))
        for (k, src), n in sorted(s["kinds"].items()):
            print(f"  {n:4d}  {k} from {src}")
        for line in seq(s["gest"]):
            print("   ", line)


if __name__ == "__main__":
    main()
