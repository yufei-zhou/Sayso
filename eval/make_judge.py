"""Build blind rubric-judging files from result files, for configs compared in one batch.

Usage: python3 eval/make_judge.py r4-v10b r4-v11
Writes eval/results/judge-<mode>[_a|_b].json (candidates shuffled, ids random) and judge-key.json (cid -> config).
Judges write eval/results/scores-<same suffix>.json; aggregate.py combines them.
"""
import json, os, random, sys, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = os.path.join(ROOT, "eval", "results")
meta = {it["id"]: it for fn in ("dataset.json", "holdout.json", "scenarios.json")
        for items in json.load(open(os.path.join(ROOT, "eval", fn))).values() for it in items}
notes = {i: it.get("note", "") for i, it in meta.items()}

random.seed(7)
items, key = {}, {}
for tag in sys.argv[1:]:
    cfg = tag.split("-", 1)[-1]
    for line in open(os.path.join(R, f"{tag}.jsonl"), encoding="utf-8"):
        rec = json.loads(line)
        if rec["style"] == "grammar" or "error" in rec:
            continue
        k = (rec["mode"], rec["id"], rec["style"])
        entry = items.setdefault(k, {"item": f"{rec['id']}/{rec['style']}", "mode": rec["mode"], "style": rec["style"],
                                     "input": rec["input"], "candidates": []})
        if notes.get(rec["id"]):
            entry["note"] = notes[rec["id"]]
        if meta.get(rec["id"], {}).get("scene"):
            entry["scene"] = meta[rec["id"]]["scene"]
        cid = uuid.uuid4().hex[:8]
        key[cid] = {"cfg": cfg, "id": rec["id"], "style": rec["style"]}
        entry["candidates"].append({"cid": cid, "text": rec["text"]})

groups = {}
for (mode, _, _), entry in sorted(items.items()):
    random.shuffle(entry["candidates"])
    groups.setdefault(mode, []).append(entry)
files = {}
for mode, entries in groups.items():
    if sum(len(e["candidates"]) for e in entries) > 110:
        half = len(entries) // 2
        files[f"{mode}_a"], files[f"{mode}_b"] = entries[:half], entries[half:]
    else:
        files[mode] = entries
for name, entries in files.items():
    json.dump(entries, open(os.path.join(R, f"judge-{name}.json"), "w"), ensure_ascii=False, indent=1)
    print(name, len(entries), "items", sum(len(e["candidates"]) for e in entries), "outputs")
json.dump(key, open(os.path.join(R, "judge-key.json"), "w"), indent=1)
