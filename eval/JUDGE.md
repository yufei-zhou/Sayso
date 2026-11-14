# Instructions for judges (native-likeness rubric)

You are judging outputs of an English-coaching app. Its user is a Chinese native speaker with advanced English whose
only goal is to learn **how native English speakers really say things in everyday life**. Judge as a native speaker of
American English in your twenties or thirties who texts friends, uses work chat, and writes emails to professors,
managers, landlords and companies. You are strict about anything that sounds like TV dialogue, ad copy, a textbook,
or a non-native trying hard to sound native.

Each item in the file has:
- `mode`: `polish` (the app rewrites the user's own English), `reply` (the app writes the user's reply to `input`,
  a message someone sent the user; an optional `note` is the user's own instruction for the reply, in Chinese or
  English), or `zh` (the app says the Chinese `input` in English).
- `scene`: who the text is for and how it is sent (when given). The app did not see this; it had to infer it.
- `style`: `sharp` (articulate, exact, dry) or `chill` (laid-back, like a twenty-something texting friends).
- `candidates`: several outputs from different versions of the app, in random order. Each is the English text,
  then a line `---`, then 0–2 phrases the app highlights for the user to learn.

Score **each candidate on its own** (never relative to the others; identical texts get identical scores).

Fields per candidate:
- `faithful` (bool): keeps the meaning, intent and facts; adds nothing (no invented reasons, plans, details,
  conditions, jokes, thanks or questions that change what is said; no assumed gender). A reply does what the note
  asks and answers what was said. Harmless conventional politeness in a reply ("Thanks!") is fine.
- `correct` (bool): grammar, word choice, punctuation.
- `native` (1–5): would a native say or write exactly this, in this scene, to this person?
  5 = indistinguishable from what a native would send. 4 = natural, a native could well say it. 3 = correct but
  slightly off (too polished, too jokey, too slangy, bookish, translated feel). 2 = clearly odd. 1 = nobody says this.
- `register` (bool): formality and tone fit the scene (an email to a professor is polite and complete; a text to a
  friend is not an email).
- `usable` (bool): the user could send it as is, with no risk of sounding odd, rude, sarcastic or try-hard.
- `tryhard` (bool): contains a bolted-on witty remark, performative slang or a showy metaphor.
- `highlights_valid` (bool): every highlighted phrase occurs verbatim in the text and is 2–6 words (no highlights at
  all counts as valid).
- `learn` (1–5): how much the highlighted expression(s) are worth learning. 5 = natives use them all the time and
  they transfer to other situations. 3 = correct but ordinary, or less common. 1 = basic words, something the user
  already wrote in the input, a rare/dated/odd phrase, or nothing highlighted.
- `voice` (1–5): how well it fits the style *as far as the scene allows* (in a formal scene, restraint is right and
  is not penalized; in casual scenes sharp should be exact and a little dry, chill relaxed and friendly).
- `issue` (string): the main problem in a few words, or "".
- `better` (string): only when `native` ≤ 3 or `usable` is false: what a native would more likely say (one line);
  otherwise "".

Write a JSON array with one object per candidate:
`{"cid": "...", "faithful": true, "correct": true, "native": 4, "register": true, "usable": true, "tryhard": false,
"highlights_valid": true, "learn": 4, "voice": 4, "issue": "", "better": ""}`
Every `cid` in the input file must appear exactly once. Validate the output with python3 (json.load, count the cids)
before finishing. Do not read any other file in `eval/results`.
