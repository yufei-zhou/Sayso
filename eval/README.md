# Sayso prompt and model evaluation

Standard: [../QUALITY.md](../QUALITY.md). Prompts: [../prompts/](../prompts/) (current = v16; earlier versions in `prompts-v*`).

## Data
- `dataset.json` — 62 dev items (27 polish with gold grammar errors, 20 reply, 15 zh).
- `holdout.json` — 35 held-out items, never used while editing prompts.

## Scripts
- `run.py --models … --tag … [--effort none]` — streams every item × task via the Responses API, records TTFT/total/tokens. `SAYSO_PROMPTS=dir` selects a prompt version.
- `score.py results/<tag>.jsonl` — latency, format checks, grammar precision/recall against gold.
- `aggregate.py` — combines blind rubric scores (`results/scores-*.json` + `judge-key.json`) into per-config quality.

## Method notes
- Pairwise LLM judging showed strong position bias (the A slot won ~3:1 when one prompt was A). Rubric judging scores each output on its own instead.
- Compare prompt versions only within the same judging batch; absolute scores drift between judge runs (v7-sol scored 0.669 in round 1, 0.623 in round 2).

## Results (gpt-6.1-sol unless noted)
Round 1 (one batch, all configs, v7 prompts):

| config | gate | voice | teach | score | TTFT p50 | total p50 |
|---|---|---|---|---|---|---|
| v7 gpt-6.1-sol | 97% | 3.46 | 3.40 | 0.669 | 1.1s | 2.1s |
| v7 gpt-6.1-terra | 96% | 3.19 | 3.15 | 0.616 | 1.0s | 1.7s |
| v7 gpt-6-luna | 91% | 3.19 | 3.03 | 0.565 | 0.6s | 1.2s |
| v6 gpt-6.1-sol | 95% | 3.67 | 3.16 | 0.655 | 1.0s | 1.9s |

gpt-6-luna at effort=low: better grammar check but TTFT 1.3–1.6s, slower than Sol; dropped.

Round 2 (same batch): v8 0.634 vs v7 0.623 overall; holdout 0.646 vs 0.587.

## Decision
- Default **gpt-6.1-sol**, reasoning effort `low` (its minimum). Terra is 8% lower in quality with similar TTFT; Luna is 16% lower. Rule from QUALITY.md: switch to a faster model only if within 5% quality and ≥30% faster.
- Fallbacks in settings: gpt-6.1-terra (effort low), gpt-6-luna (effort none).
- Grammar check: Sol precision 1.00, recall ~0.89 on 46 gold errors.

## Known remaining weaknesses
Occasional trivial notes (take a look, that sucks), sharp voice sometimes flat on short inputs, rare misreadings in reply ("the city" → "which city?").

## Round 3: highlight-only output (v9, 2026-11-08)
The app no longer shows explanations: outputs end with 1–2 phrases to highlight, grammar reasons are English and shown on hover. Prompts: `prompts-v9`. Same-batch rubric judging of all three models:

| model | gate | voice | teach | highlights valid | score | TTFT p50 | total p50 |
|---|---|---|---|---|---|---|---|
| gpt-6.1-sol | 96% | 3.58 | 3.67 | 91% | 0.695 | 1.0s | 1.4–1.7s |
| gpt-6.1-terra | 98% | 3.20 | 3.36 | 89% | 0.633 | 0.8s | 1.2s |
| gpt-6-luna | 90% | 3.09 | 3.15 | 77% | 0.550 | 0.6s | 1.0s |

Default stays gpt-6.1-sol. The app drops highlights that don't occur in the text (and normalizes quotes), which covers most invalid ones; the remaining weakness is sometimes highlighting a basic phrase instead of the fix.

## Round 4: prompt review fixes (v11, v12, 2026-11-08)
An independent review (Fable) found the few-shot examples contradicting the rules: invented facts and bolted-on jokes in Reply, trivial or non-verbatim highlights, a stretched spelling taught as a phrase. Clear bugs were fixed in place (v10b = v10 + verbatim highlight, 6-word limit, "suggest that I"). Then:
- **v11**: rewrote the offending examples; Reply allows a plain cooperative yes/no and no longer says "ask a question instead"; register rule in Polish; Chill rules merged and an emoji may end a message; format rule says "give just 1 when only one is worth it"; Sharp told that a plain deadpan version is fine on short inputs.
- **v12**: v11 but with the v10 Sharp voice file, plus "get there through word choice and framing, never by adding a quip, condition or detail".

Same-batch rubric judging, gpt-6.1-sol, 200 outputs per config (`make_judge.py r4-v10b r4-v11 r4-v12`, scores in `results/round4b`):

| config | gate | voice | teach | forced | highlights valid | score | dev | holdout |
|---|---|---|---|---|---|---|---|---|
| v10b | 94% | 3.58 | 3.65 | 2% | 80% | 0.670 | 0.665 | 0.680 |
| v11 | 97% | 3.29 | 3.60 | 0% | 82% | 0.656 | 0.644 | 0.676 |
| **v12** | 96% | 3.56 | 3.67 | 2% | 85% | **0.688** | 0.686 | 0.691 |

v11 made Sharp flat (voice 2.93, "plain for sharp" ×18). v12 keeps Sharp's voice and gains in Reply (0.636 vs 0.583) and Chill (0.697 vs 0.664). Latency unchanged (TTFT p50 ~1.0s). **v12 adopted.** Grammar check unchanged: precision 1.00, recall 0.87–0.89.

## Round 5: "would a native really say this?" (v13–v15, 2026-11-09)
The goal was restated: learn how native speakers really talk in everyday life. QUALITY.md was rewritten around that
(native-likeness, register and "usable as is" are gates; the voice is secondary), and a new set, `scenarios.json`
(80 inputs with a `scene`: emails to professors, work chat, friends, landlord/support, Chinese to English), was added.
Judging uses `JUDGE.md` + `aggregate_native.py`; scores are **not comparable** with rounds 1–4.

Reading v12's outputs showed: Chill is solid; Sharp tacks a "clever" second sentence onto replies ("Let's keep it
simple" to customer support, "fair game" to a professor); emails to professors get turned into chat messages.
- **v13**: situation first (who it's for, which medium), everyday wording first, no extra clever sentence, emails stay
  emails, formal examples added. Fixed the above, but the two voices often came out identical.
- **v14**: voices told how to differ within a register (Sharp = concise and exact, Chill = warm), keep the tone of
  playful Chinese, offer a second natural option when the input is already native.
- **v15**: v14 + American wording, friend-like sympathy, stricter verbatim highlights that prefer what a learner
  wouldn't have come up with.

| set (same batch) | version | gate | native (1–5) | native ≥ 4 | try-hard | learn | score |
|---|---|---|---|---|---|---|---|
| scenarios, round 5a | v12 | 93% | 4.21 | 81% | 9% | 3.99 | 0.774 |
| | v13 | 99% | 4.49 | 94% | 0% | 3.65 | 0.821 |
| | v14 | 99% | 4.49 | 92% | 0% | 3.66 | 0.818 |
| scenarios, round 5b | v14 | 99% | 4.44 | 92% | 0% | 3.72 | 0.822 |
| | **v15** | 99% | 4.41 | 92% | 0% | 3.83 | 0.823 |
| old holdout (never tuned on), 5b | v12 | 87% | 4.24 | 84% | 7% | 3.72 | 0.731 |
| | **v15** | 99% | 4.42 | 89% | 0% | 3.50 | 0.801 |

**v15 adopted.** Biggest gain: Sharp (holdout 0.627 → 0.778; gate 76% → 100%). Speed and grammar check unchanged
(TTFT p50 ~1.1 s; precision 1.00, recall 0.87). Known weak spots: highlights are sometimes ordinary (learn ≈ 3.5–3.8),
Chinese slang with no English equivalent (卷, 社死) comes out explained rather than said, and the judges are language
models, not native speakers.

## Latency note (2026-11-10): one mode × voice suddenly taking 5–10 s
Polish + Sharp started taking 5–10 s to show its first word while every other combination took ~1.2 s, with zero
reasoning tokens. Cause: OpenAI routes requests by the beginning of the prompt (for its prompt cache), and the machines
serving that particular beginning were backed up. The identical request with one invisible whitespace character in
front of the instructions came back in ~1.3 s; a random `prompt_cache_key` did not help. The app now (1) starts each
request's instructions with a randomly chosen invisible prefix and (2) sends a second request down another route if no
text has arrived after 2 s, using whichever answers first (`OpenAIClient.stream`). `events.log` records per-stream
timings (`run: … sharp first=… done=…`) and each second-route attempt, never the text.

## Round 6: do the few-shot examples help? (2026-11-11)
Same prompts (v15) with and without `examples.json`, on the 80 scenarios + the 38-item holdout, one blind batch,
236 outputs each (`results/round6`).

| | gate | native | learn (highlights) | voice | score | prompt tokens | first word p50 (Sharp / Chill) |
|---|---|---|---|---|---|---|---|
| with examples | 98% | 4.56 | 3.85 | 4.14 | 0.837 | ~1330 | 1.47 s / 1.27 s |
| without | 99% | 4.52 | 3.95 | 4.22 | 0.852 | ~1100 | 1.55 s / 1.31 s |

Paired difference (with − without): score −0.015 (95% CI −0.036…+0.006), highlights' learning value −0.10
(CI −0.19…−0.01), native-likeness +0.04 (CI −0.03…+0.12). The examples don't help any more: the written rules now
carry the behaviour, and the examples nudge the model toward the same few highlight phrases. Format compliance is the
same without them. **v16 = v15 without examples, adopted.** The app no longer sends or edits examples at all (removed from the
Settings › Prompts list on 2026-11-14, since writing them meant hand-editing JSON); `eval/run.py` still accepts an
optional `examples.json` in a prompt folder for experiments.
