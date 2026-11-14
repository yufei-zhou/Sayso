"""Summarize a results file: latency, tokens, format compliance, grammar precision/recall.

Usage: python3 eval/score.py eval/results/v1.jsonl
Style quality is judged separately (blind review); this covers what can be checked mechanically.
"""
import json, os, statistics, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
gold = {it["id"]: it for fn in ("dataset.json", "holdout.json") for it in json.load(open(os.path.join(ROOT, "eval", fn)))["polish"]}


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")


def overlaps(a, b):
    a, b = a.lower(), b.lower()
    return a in b or b in a


def check_style(rec):
    """Return list of format problems for a sharp/chill output."""
    probs = []
    text = rec["text"]
    if "\n---" not in "\n" + text:
        return ["no ---"]
    body, notes = text.split("---", 1)
    body = body.strip()
    if not body:
        probs.append("empty body")
    if body.startswith('"'):
        probs.append("quoted")
    lines = [l.strip() for l in notes.splitlines() if l.strip()]
    if len(lines) > 2:
        probs.append(f"{len(lines)} highlights")
    for line in lines:
        phrase = line.split(" — ", 1)[0].strip().strip('"')
        if " — " in line:
            probs.append("explanation present")
        if phrase.lower() not in body.lower():
            probs.append(f"phrase not in text: {phrase[:30]}")
    if rec["mode"] == "polish" and len(rec["input"]) > 30 and len(body) > 1.8 * len(rec["input"]):
        probs.append(f"too long x{len(body) / len(rec['input']):.1f}")
    return probs


def main(path):
    recs = [json.loads(l) for l in open(path, encoding="utf-8")]
    by_model = defaultdict(list)
    for r in recs:
        by_model[r["model"]].append(r)

    for model, rs in by_model.items():
        ok = [r for r in rs if "error" not in r]
        print(f"\n=== {model}  ({len(ok)}/{len(rs)} ok)")
        for style in ("sharp", "chill", "grammar"):
            s = [r for r in ok if r["style"] == style]
            if not s:
                continue
            ttft = [r["ttft"] for r in s if r["ttft"] is not None]
            tot = [r["total"] for r in s]
            out_tok = [r["usage"]["output_tokens"] for r in s if r.get("usage")]
            reason = [r["usage"].get("output_tokens_details", {}).get("reasoning_tokens", 0) for r in s if r.get("usage")]
            print(f"  {style:7} ttft p50 {pct(ttft, .5):.2f}s p90 {pct(ttft, .9):.2f}s | total p50 {pct(tot, .5):.2f}s p90 {pct(tot, .9):.2f}s"
                  f" | out tok avg {statistics.mean(out_tok or [0]):.0f} (reasoning {statistics.mean(reason or [0]):.0f})")

        fmt = [(r["id"], r["style"], p) for r in ok if r["style"] != "grammar" for p in check_style(r)]
        print(f"  format problems: {len(fmt)}")
        for f in fmt[:8]:
            print(f"    {f}")

        tp = fp = fn = bad_json = 0
        fps, fns = [], []
        for r in (r for r in ok if r["style"] == "grammar"):
            found = []
            for line in filter(None, (l.strip() for l in r["text"].splitlines())):
                try:
                    o = json.loads(line)
                    if o["wrong"] not in r["input"]:
                        bad_json += 1
                    found.append(o)
                except Exception:
                    bad_json += 1
            g = gold[r["id"]]["errors"]
            matched = set()
            for o in found:
                hit = next((i for i, (w, _) in enumerate(g) if i not in matched and overlaps(o["wrong"], w)), None)
                if hit is None:
                    fp += 1
                    fps.append((r["id"], o["wrong"], o["fix"]))
                else:
                    matched.add(hit)
                    tp += 1
            for i, (w, fix) in enumerate(g):
                if i not in matched:
                    fn += 1
                    fns.append((r["id"], w))
        if tp + fp + fn:
            print(f"  grammar: precision {tp / max(1, tp + fp):.2f} recall {tp / max(1, tp + fn):.2f}"
                  f" (tp {tp} fp {fp} fn {fn}, unparseable/non-substring {bad_json})")
            for x in fps:
                print(f"    FP {x}")
            for x in fns:
                print(f"    FN {x}")


if __name__ == "__main__":
    main(sys.argv[1])
