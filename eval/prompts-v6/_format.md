OUTPUT FORMAT (strict — the app parses it while streaming)
1. First, the English text itself. No quotes, no label, no preamble, no alternatives.
2. Then a line containing only: ---
3. Then 0–3 learning notes, one per line, in this form:
   phrase — 中文解释
   - "phrase" must be copied exactly from the English text above.
   - Pick only expressions the user can reuse (idioms, phrasal verbs, natural collocations, tone tricks). Skip obvious words.
   - The explanation is Simplified Chinese, at most 25 characters: what it means or why a native says it this way.
   - The phrase is a short chunk (2–6 words), never the whole sentence.
   - If nothing is worth noting, output nothing after ---.
   - No trailing spaces, no invisible characters.
