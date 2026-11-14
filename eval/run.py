"""Run the eval set against OpenAI models with streaming, recording latency and output.

Usage: python3 eval/run.py --models gpt-5.6-luna gpt-5.6-terra --tag v1 [--only p01,r02] [--effort none]
Writes eval/results/<tag>.jsonl (one line per model x item x task).
The API key is read from the Keychain (service "Sayso", account "openai").
"""
import argparse, json, os, re, subprocess, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPTS = os.environ.get("SAYSO_PROMPTS", os.path.join(ROOT, "prompts"))


def read(name):
    with open(os.path.join(PROMPTS, name), encoding="utf-8") as f:
        return f.read().strip()


def build_prompt(mode, style):
    """Compose task + voice + format; keep only lines tagged for this style."""
    if style is None:
        return read("grammar.md")
    lines = []
    for line in read(f"{mode}.md").splitlines():
        m = re.match(r"\[(sharp|chill)\] ?(.*)", line)
        if m:
            if m.group(1) == style:
                lines.append(m.group(2))
        else:
            lines.append(line)
    return "\n".join(lines) + "\n\n" + read(f"_{style}.md") + "\n\n" + read("_format.md")


def build_input(mode, style, text):
    """Few-shot examples as prior turns, then the real input."""
    if style is None:
        return text
    path = os.path.join(PROMPTS, "examples.json")  # optional; the app no longer uses examples (round 6)
    ex = json.load(open(path, encoding="utf-8")).get(f"{mode}_{style}", []) if os.path.exists(path) else []
    msgs = []
    for i, o in ex:
        msgs += [{"role": "user", "content": i}, {"role": "assistant", "content": o}]
    return msgs + [{"role": "user", "content": text}]


def user_turn(mode, item):
    """Same shape the app sends: reply mode labels the message and the optional note."""
    if mode != "reply":
        return item["text"]
    note = item.get("note", "")
    return "Message:\n" + item["text"] + (f"\n\nMy note: {note}" if note else "")


def tasks_for(mode):
    out = [(mode, "sharp"), (mode, "chill")]
    if mode == "polish":
        out.append((mode, None))
    return out


def api_key():
    if os.environ.get("SAYSO_EVAL_KEY"):  # read once by the caller, so several runs ask the Keychain only once
        return os.environ["SAYSO_EVAL_KEY"]
    return subprocess.run(["security", "find-generic-password", "-s", "Sayso", "-a", "openai", "-w"],
                          capture_output=True, text=True, check=True).stdout.strip()


MIN_EFFORT = {"gpt-6.1-sol": "low", "gpt-6.1-terra": "low"}  # these reject 'none'


def stream(key, model, system, user, effort):
    body = {"model": model, "instructions": system, "input": user, "stream": True, "store": False}
    if effort:
        if effort == "none" and model in MIN_EFFORT:
            effort = MIN_EFFORT[model]
        body["reasoning"] = {"effort": effort}
    req = urllib.request.Request("https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft, text, usage = None, [], None
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                ev = json.loads(line[5:])
                if ev.get("type") == "response.output_text.delta":
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    text.append(ev["delta"])
                elif ev.get("type") == "response.completed":
                    usage = ev["response"].get("usage")
                elif ev.get("type") in ("error", "response.failed"):
                    return {"error": json.dumps(ev)[:500]}
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()[:500]}"}
    except Exception as e:  # network, timeout
        return {"error": repr(e)}
    return {"ttft": ttft, "total": time.monotonic() - t0, "text": "".join(text), "usage": usage}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--effort", default="none", help="reasoning effort; '' to omit")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--sets", default="dataset.json,holdout.json", help="comma-separated item files in eval/")
    a = ap.parse_args()

    data = {}
    for fn in a.sets.split(","):
        for mode, items in json.load(open(os.path.join(ROOT, "eval", fn), encoding="utf-8")).items():
            data.setdefault(mode, []).extend(items)
    only = set(filter(None, a.only.split(",")))
    jobs = []
    for mode, items in data.items():
        for it in items:
            if only and it["id"] not in only:
                continue
            for m, style in tasks_for(mode):
                for model in a.models:
                    jobs.append((model, m, style, it))

    key = api_key()
    os.makedirs(os.path.join(ROOT, "eval", "results"), exist_ok=True)
    out_path = os.path.join(ROOT, "eval", "results", f"{a.tag}.jsonl")

    def run(job):
        model, mode, style, it = job
        res = stream(key, model, build_prompt(mode, style), build_input(mode, style, user_turn(mode, it)) if style else it["text"], a.effort)
        return {"model": model, "mode": mode, "style": style or "grammar", "id": it["id"],
                "input": it["text"], "effort": a.effort, **res}

    done = 0
    with open(out_path, "w", encoding="utf-8") as f, ThreadPoolExecutor(a.workers) as ex:
        for rec in ex.map(run, jobs):
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            done += 1
            if "error" in rec:
                print(f"[{done}/{len(jobs)}] {rec['model']} {rec['id']} {rec['style']}: {rec['error'][:200]}", file=sys.stderr)
    print(f"wrote {out_path} ({len(jobs)} runs)")


if __name__ == "__main__":
    main()
