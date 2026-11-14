"""Combine rubric scores (eval/results/scores-*.json) with the blind key into per-config quality, split by set and mode."""
import glob, json, os, statistics as st
from collections import defaultdict

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
key = json.load(open(os.path.join(R, "judge-key.json")))
rows = [s for f in glob.glob(os.path.join(R, "scores-*.json")) for s in json.load(open(f))]


def composite(s):
    if not (s["faithful"] and s["correct"] and s["natural"]):
        return 0.0
    return max(0.0, (s["voice"] + s["teach"]) / 10 - 0.1 * s["forced"] - 0.1 * (not s.get("highlights_valid", s.get("notes_accurate"))))


agg = defaultdict(list)
for s in rows:
    k = key[s["cid"]]
    held = "holdout" if k["id"].startswith("h") else "dev"
    mode = {"p": "polish", "r": "reply", "c": "zh"}[k["id"].lstrip("h")[0]]
    for group in (("all",), (held,), (mode,), (k["style"],)):
        agg[(k["cfg"],) + group].append(s)

cfgs = sorted({k[0] for k in agg})
print(f"{'config':10} {'slice':8} {'n':>4} {'gate%':>6} {'voice':>6} {'teach':>6} {'forced%':>8} {'notesOK%':>9} {'score':>6}")
for c in cfgs:
    for g in ("all", "dev", "holdout", "polish", "reply", "zh", "sharp", "chill"):
        xs = agg.get((c, g), [])
        if not xs:
            continue
        gate = sum(x["faithful"] and x["correct"] and x["natural"] for x in xs) / len(xs)
        print(f"{c:10} {g:8} {len(xs):4} {gate*100:6.0f} {st.mean(x['voice'] for x in xs):6.2f} {st.mean(x['teach'] for x in xs):6.2f}"
              f" {st.mean(x['forced'] for x in xs)*100:8.0f} {st.mean(x.get("highlights_valid", x.get("notes_accurate")) for x in xs)*100:9.0f} {st.mean(map(composite, xs)):6.3f}")
    print()

issues = defaultdict(lambda: defaultdict(int))
for s in rows:
    if s.get("issue"):
        issues[key[s["cid"]]["cfg"]][s["issue"].lower()[:40]] += 1
for c in cfgs:
    print(c, sorted(issues[c].items(), key=lambda x: -x[1])[:6])
