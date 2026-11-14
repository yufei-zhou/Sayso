"""Combine native-likeness scores (results/scores-*.json, rubric in JUDGE.md / QUALITY.md) into per-version quality.

Usage: python3 eval/aggregate_native.py [--notes N]   (N = how many judge remarks to print per version)
"""
import glob, json, os, statistics as st, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, "results")
key = json.load(open(os.path.join(R, "judge-key.json")))
rows = [s for f in sorted(glob.glob(os.path.join(R, "scores-*.json"))) for s in json.load(open(f))]
meta = {it["id"]: it for fn in ("dataset.json", "holdout.json", "scenarios.json")
        for items in json.load(open(os.path.join(HERE, fn))).values() for it in items}
FORMAL = ("professor", "supervisor", "recruiter", "landlord", "customer", "restaurant", "manager", "stranger")


def gate(s):
    return bool(s["faithful"] and s["correct"] and s["register"] and s["usable"])


def composite(s):
    if not gate(s):
        return 0.0
    base = (0.5 * s["native"] + 0.35 * s["learn"] + 0.15 * s["voice"]) / 5
    return max(0.0, base - 0.1 * bool(s["tryhard"]) - 0.1 * (not s["highlights_valid"]))


def mode_of(item_id):
    return {"p": "polish", "r": "reply", "c": "zh"}[item_id.lstrip("hs")[0]]


agg = defaultdict(list)
for s in rows:
    k = key[s["cid"]]
    scene = meta.get(k["id"], {}).get("scene", "")
    kind = "formal" if any(w in scene for w in FORMAL) else "casual"
    for group in ("all", mode_of(k["id"]), k["style"], kind):
        agg[(k["cfg"], group)].append(s)

cfgs = sorted({c for c, _ in agg})
print(f"{'version':8} {'slice':7} {'n':>4} {'gate%':>6} {'native':>7} {'nat>=4%':>8} {'usable%':>8} {'regist%':>8} {'tryhard%':>9} {'learn':>6} {'voice':>6} {'hlOK%':>6} {'score':>6}")
for c in cfgs:
    for g in ("all", "polish", "reply", "zh", "sharp", "chill", "formal", "casual"):
        xs = agg.get((c, g), [])
        if not xs:
            continue
        pct = lambda f: 100 * sum(map(f, xs)) / len(xs)
        print(f"{c:8} {g:7} {len(xs):4} {pct(gate):6.0f} {st.mean(x['native'] for x in xs):7.2f} {pct(lambda x: x['native'] >= 4):8.0f}"
              f" {pct(lambda x: x['usable']):8.0f} {pct(lambda x: x['register']):8.0f} {pct(lambda x: x['tryhard']):9.0f}"
              f" {st.mean(x['learn'] for x in xs):6.2f} {st.mean(x['voice'] for x in xs):6.2f} {pct(lambda x: x['highlights_valid']):6.0f}"
              f" {st.mean(map(composite, xs)):6.3f}")
    print()

if "--notes" in sys.argv:
    n = int(sys.argv[sys.argv.index("--notes") + 1])
    for c in cfgs:
        print(f"== {c}: lowest-scoring outputs")
        bad = sorted((s for s in rows if key[s["cid"]]["cfg"] == c and (s["native"] <= 3 or not gate(s))), key=composite)
        for s in bad[:n]:
            k = key[s["cid"]]
            print(f"  {k['id']}/{k['style']} native={s['native']} usable={s['usable']} | {s['issue']} | better: {s.get('better', '')}")
