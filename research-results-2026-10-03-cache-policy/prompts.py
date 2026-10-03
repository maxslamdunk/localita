"""Training and validation prompts for cache-policy replay.

Deliberately unlike one another (code, math, other languages, creative
writing, structured output, long pasted input, multi-turn) so a policy fitted
on them has to generalize. The three real-generation-v1 prompts are not here:
they are the held-out test set. `split` assigns each prompt to `train` or
`val`, fixed before any policy is scored.
"""

PASSAGE = (
    "The Great Stink of 1858 was a period in central London during which the hot weather "
    "exacerbated the smell of untreated human waste and industrial effluent present on the "
    "banks of the River Thames. The problem had been mounting for some years, with an ageing "
    "and inadequate sewer system that emptied directly into the Thames. The miasma from the "
    "effluent was thought to transmit contagious diseases, and three outbreaks of cholera before "
    "the Great Stink were blamed on the ongoing problems with the river. The smell, and people's "
    "fears of its possible effects, prompted action from the national and local administrators "
    "who had been considering possible solutions for the problem. The authorities accepted a "
    "proposal from the civil engineer Joseph Bazalgette to move the effluent eastwards along a "
    "series of interconnecting sewers that sloped towards outfalls beyond the metropolitan area. "
    "Work on the new northern and southern sewer systems started at the beginning of 1859 and "
    "lasted until 1875. To aid the drainage, pumping stations were placed to lift the sewage from "
    "lower levels into higher pipes. Two of the more ornate stations, Abbey Mills in Stratford and "
    "Crossness on the Erith Marshes, are listed for protection by English Heritage. Bazalgette's "
    "plan introduced the three embankments to London: the Victoria, Chelsea and Albert. "
)

CODE = '''def merge_intervals(intervals):
    intervals.sort()
    out = []
    for s, e in intervals:
        if out and s < out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out
'''


def user(text):
    return [{"role": "user", "content": text}]


PROMPTS = [
    # name, split, max_new, messages
    ("py-lru", "train", 700, user(
        "Write a Python class implementing an LRU cache with O(1) get and put, using only the "
        "standard library. Include type hints, docstrings, and five pytest tests.")),
    ("swift-actor", "train", 600, user(
        "Explain Swift actors and actor reentrancy with a short example that has a subtle "
        "reentrancy bug, then show the fixed version.")),
    ("sql-debug", "val", 500, user(
        "This query is slow on a 50M-row table: SELECT * FROM orders WHERE DATE(created_at) = "
        "'2024-05-01' AND status <> 'cancelled' ORDER BY total DESC LIMIT 20; Explain why and "
        "rewrite it, including the index you would add.")),
    ("bash-backup", "train", 500, user(
        "Write a bash script that backs up a directory to a timestamped tar.gz, keeps only the "
        "last 7 backups, and logs errors to stderr. Use set -euo pipefail and explain each part.")),
    ("code-review", "train", 600, user(
        "Review this function for bugs and edge cases, then give a corrected version with "
        "tests:\n\n```python\n" + CODE + "```")),
    ("rust-borrow", "val", 500, user(
        "In Rust, why does pushing to a Vec while holding a reference to one of its elements "
        "fail to compile? Show the error, explain it in terms of memory safety, and give three "
        "ways to restructure the code.")),
    ("math-proof", "train", 500, user(
        "Prove that there are infinitely many primes congruent to 3 mod 4. Be rigorous but "
        "explain the key idea first.")),
    ("prob-puzzle", "train", 600, user(
        "Three people each flip a fair coin repeatedly until they get two heads in a row. What is "
        "the expected number of flips until all three are done? Work it out step by step, "
        "starting with the expectation for one person.")),
    ("logic-grid", "val", 600, user(
        "Five houses in a row are painted different colors and owned by people of different "
        "nationalities who drink different drinks. The Norwegian lives in the first house. The "
        "green house is immediately left of the white one. The Brit lives in the red house. The "
        "person in the middle house drinks milk. Explain how far these clues alone determine the "
        "arrangement, and what extra clue would make it unique.")),
    ("ru-history", "train", 600, user(
        "Расскажи кратко об истории Санкт-Петербурга: основание, роль столицы, блокада Ленинграда "
        "и современный город. Ответ на русском языке, около 400 слов.")),
    ("de-letter", "train", 500, user(
        "Schreibe einen höflichen, aber bestimmten Brief an einen Vermieter, in dem du um die "
        "Reparatur einer seit drei Wochen defekten Heizung bittest. Nenne eine Frist und "
        "mögliche Konsequenzen.")),
    ("es-recipe", "val", 500, user(
        "Dame una receta detallada de paella valenciana tradicional para seis personas, con la "
        "lista de ingredientes, los pasos y los errores más comunes que hay que evitar.")),
    ("zh-explain", "train", 500, user(
        "请用通俗易懂的中文解释什么是区块链，它如何保证数据不被篡改，以及它有哪些局限性。")),
    ("ja-haiku", "train", 300, user(
        "秋をテーマにした俳句を五つ作り、それぞれの俳句の意味と季語を日本語で説明してください。")),
    ("fr-translate", "val", 500, user(
        "Translate the following passage into French, keeping the tone formal, then list three "
        "phrases that were hard to translate and why:\n\n" + PASSAGE[:900])),
    ("story", "train", 800, user(
        "Write a short story (about 600 words) about a lighthouse keeper who discovers that the "
        "light has been guiding something other than ships. Use close third person and end "
        "ambiguously.")),
    ("poem", "train", 300, user(
        "Write a sonnet about debugging code at 3 a.m., in iambic pentameter with a Shakespearean "
        "rhyme scheme.")),
    ("dialogue", "val", 600, user(
        "Write a dialogue between a skeptical economist and an enthusiastic urban planner arguing "
        "about congestion pricing. Each should make at least three strong points.")),
    ("json-extract", "train", 400, user(
        "Extract every person, place, date and organization from this passage as JSON with keys "
        "people, places, dates, organizations, each a list of strings. Output only JSON.\n\n"
        + PASSAGE)),
    ("summarize-long", "train", 400, user(
        "Summarize the passage below in five bullet points for a high-school student, then give "
        "one question for discussion.\n\n" + PASSAGE * 3)),
    ("compare-table", "val", 600, user(
        "Compare PostgreSQL, SQLite, MongoDB and Redis in a markdown table across data model, "
        "durability, concurrency, typical use, and operational cost. Then recommend one for a "
        "small mobile app's local storage and justify it.")),
    ("travel-chat", "train", 500, user(
        "hey! going to lisbon for 4 days in november with my partner, we like food and walking "
        "but hate crowds. what should we do? budget is moderate")),
    ("email-advice", "train", 400, user(
        "My coworker keeps taking credit for my work in meetings. How do I bring it up with my "
        "manager without sounding petty? Give me a short script I could use.")),
    ("multi-turn", "val", 500, [
        {"role": "user", "content": "What's the difference between a process and a thread?"},
        {"role": "assistant", "content": "A process is an independent program in execution with "
         "its own address space, while threads are units of execution inside a process that "
         "share its memory. Creating and switching threads is cheaper, but shared memory means "
         "threads need synchronization to avoid data races."},
        {"role": "user", "content": "OK, so how do Go's goroutines fit in? And why can I start a "
         "million of them but not a million OS threads?"}]),
    ("science", "train", 600, user(
        "Explain how CRISPR-Cas9 edits a genome, from guide RNA design to DNA repair pathways, and "
        "discuss two current limitations in therapeutic use.")),
    ("finance", "train", 500, user(
        "Explain the difference between a Roth and a traditional retirement account with a "
        "numeric example over 30 years, and state the assumptions that decide which is better.")),
]
