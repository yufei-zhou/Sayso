OUTPUT FORMAT (strict — the app parses it while streaming)
1. First, the English text itself. No quotes, no label, no preamble, no alternatives.
2. Then a line containing only: ---
3. Then 0–3 learning notes, one per line, in this form:
   phrase — 中文解释
   - "phrase" must be copied exactly from the English text above.
   - Pick only expressions the user can reuse (idioms, phrasal verbs, natural collocations, tone tricks). Skip obvious words.
   - The explanation is Simplified Chinese, at most 25 characters: what it means or why a native says it this way.
   - The phrase is a short chunk (2–6 words), never the whole sentence.
   - In polish mode, prefer the phrase that replaced something the user got wrong or said unnaturally.
   - Explain what the phrase itself means, accurately, not just its role in this sentence.
   - Usually give 1–2 notes; output nothing after --- only when every phrase is basic.
   - No trailing spaces, no invisible characters.
