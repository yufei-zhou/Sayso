"""Print a results file side by side for reading: python3 eval/show.py results/<tag>.jsonl [id-prefix]"""
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
prefix = sys.argv[2] if len(sys.argv) > 2 else ""
by = {}
for r in recs:
    by.setdefault(r["id"], {})[r["style"]] = r
notes = {it["id"]: it for fn in ("dataset.json", "holdout.json", "scenarios.json") for items in json.load(open(__file__.rsplit("/", 1)[0] + "/" + fn)).values() for it in items}
for i in sorted(by):
    if not i.startswith(prefix): continue
    it = notes.get(i, {})
    print(f"[{i}] ({it.get('scene','')}) {by[i]['sharp']['input']!r}" + (f"  NOTE: {it['note']}" if it.get("note") else ""))
    for style in ("sharp", "chill", "grammar"):
        if style in by[i]:
            t = by[i][style].get("text", by[i][style].get("error", "")).strip()
            if style == "grammar":
                t = "; ".join(f"{json.loads(l)['wrong']} → {json.loads(l)['fix']}" for l in t.splitlines() if l.strip().startswith("{")) or "(none)"
            else:
                body, _, hl = t.partition("\n---")
                t = body.strip().replace("\n", " ⏎ ") + "   ⟦" + " | ".join(x.strip() for x in hl.strip().splitlines()) + "⟧"
            print(f"   {style:7} {t}")
