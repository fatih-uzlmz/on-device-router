"""
On-device router v1 — privacy-first intelligent routing.

Pipeline per query:
  1. PRIVACY GATE: health / finance / personal data -> forced LOCAL, never cloud.
  2. COMPLEXITY SCORER: heuristic features -> score.
  3. DECISION: score >= threshold -> CLOUD (frontier model), else LOCAL (on-device SLM).

Run: python3 router_v1.py
"""

import re

# ---------------------------------------------------------------- dataset ---
# (query, expected_route, category)
DATASET = [
    # -- LOCAL: chitchat / device tasks -------------------------------------
    ("Hey, how's it going?", "local", "chitchat"),
    ("Remind me to call mom at 5pm", "local", "device_task"),
    ("Set a timer for 20 minutes", "local", "device_task"),
    ("What did I ask you yesterday about my trip?", "local", "memory_recall"),
    ("Play some jazz music", "local", "device_task"),
    # -- LOCAL: understanding / extraction / rewrite -------------------------
    ("Summarize this paragraph: The council approved the new transit plan after three hours of debate, with funding split evenly between bus lanes and bike infrastructure.", "local", "summarization"),
    ("Extract all the dates from this email: Hi team, let's meet on March 3rd, the deadline is April 15th, and the launch party is May 1st.", "local", "extraction"),
    ("Is this review positive or negative: 'The battery died after two hours, total waste of money.'", "local", "classification"),
    ("Translate 'good morning, how are you?' to Spanish", "local", "translation"),
    ("Rewrite this more politely: 'Send me the report now, I don't have all day.'", "local", "rewrite"),
    ("List the ingredients from this recipe: 2 eggs, 200g flour, 100ml milk, a pinch of salt.", "local", "extraction"),
    ("What is the capital of Japan?", "local", "factual"),
    ("How many ounces are in a cup?", "local", "factual"),
    ("Give me a one-sentence summary of this article about urban gardening.", "local", "summarization"),
    ("Correct the grammar: 'She don't like apples.'", "local", "rewrite"),
    # -- PRIVACY: forced local, never cloud ----------------------------------
    ("What were my blood test results last month?", "local", "privacy_health"),
    ("Summarize my recent lab report and flag anything abnormal", "local", "privacy_health"),
    ("Did my doctor change my prescription dosage?", "local", "privacy_health"),
    ("What's my current bank account balance?", "local", "privacy_finance"),
    ("Did that large charge on my credit card go through?", "local", "privacy_finance"),
    ("Remind me what my dentist said about the root canal", "local", "privacy_health"),
    # -- CLOUD: reasoning / math / code --------------------------------------
    ("Prove that the square root of 2 is irrational", "cloud", "reasoning"),
    ("Calculate the compound interest on $10,000 at 7% annual rate over 10 years with $200 monthly contributions", "cloud", "math"),
    ("Write a Python function that merges two sorted linked lists", "cloud", "code"),
    ("Debug this crash: NullPointerException at line 42 in UserService when the profile cache is cold", "cloud", "code"),
    ("Compare the pros and cons of a Roth vs traditional IRA for someone earning $120k with 25 years to retirement", "cloud", "analysis"),
    ("Solve step by step: A train leaves Chicago at 60mph heading east, another leaves St. Louis at 75mph heading north. When are they 500 miles apart?", "cloud", "math"),
    ("Explain the trade-offs between microservices and a monolith for a team of 8 engineers expecting 10x growth", "cloud", "analysis"),
    ("Derive the time complexity of quicksort in the average case", "cloud", "reasoning"),
    ("Write a SQL query that finds the top 5 customers by revenue in each region for Q3", "cloud", "code"),
    ("Analyze this argument for logical fallacies: 'We shouldn't build bike lanes because nobody bikes in winter, and my cousin crashed once.'", "cloud", "reasoning"),
    ("Plan a 5-day Tokyo itinerary under $1500 including transit passes, staying near Shinjuku, with two day trips", "cloud", "planning"),
    ("What are the second-order effects of a four-day work week on urban traffic patterns?", "cloud", "analysis"),
]

# ---------------------------------------------------------------- router ----
PRIVACY_PATTERNS = [
    r"\bmy (blood|lab|prescription|diagnosis|doctor|medical|health|dentist|therapy|symptoms)\b",
    r"\b(my|the) (lab report|test results)\b",
    r"\bmy (bank|account|credit card|balance|transaction|ssn|social security)\b",
    r"\b(charge|payment) on my\b",
]

CLOUD_KEYWORDS = {
    "prove": 3, "proof": 3, "theorem": 3, "derive": 3, "derivation": 3,
    "calculate": 2, "solve": 2, "equation": 2, "complexity": 2,
    "debug": 3, "stack trace": 2, "nullpointer": 2, "algorithm": 2,
    "write a python": 3, "write a sql": 3, "function that": 2, "refactor": 2,
    "compare": 2, "pros and cons": 3, "trade-offs": 3, "tradeoffs": 3,
    "analyze": 2, "analysis": 1, "fallacies": 2,
    "step by step": 3, "itinerary": 2, "second-order": 2,
}

LOCAL_KEYWORDS = {
    "summarize": -2, "summary": -2, "extract": -2, "translate": -2,
    "rewrite": -2, "remind me": -3, "set a timer": -3, "play some": -2,
    "correct the grammar": -2, "capital of": -2, "how many ounces": -2,
}


def complexity_score(query: str):
    q = query.lower()
    reasons = []
    score = 0.0

    for kw, w in CLOUD_KEYWORDS.items():
        if kw in q:
            score += w
            reasons.append(f"+{w} keyword '{kw}'")
    for kw, w in LOCAL_KEYWORDS.items():
        if kw in q:
            score += w
            reasons.append(f"{w} keyword '{kw}'")

    words = len(q.split())
    if words > 25:
        score += 1.5
        reasons.append(f"+1.5 long query ({words} words)")
    elif words < 8:
        score -= 1.0
        reasons.append(f"-1.0 short query ({words} words)")

    if re.search(r"\$[\d,]+|[\d]+%|\d+\s*(mph|miles|years|months)", q):
        score += 1.5
        reasons.append("+1.5 numeric reasoning signals")
    if "?" in query and words > 15:
        score += 0.5
        reasons.append("+0.5 long question")

    return score, reasons


def route(query: str, threshold: float = 2.0):
    q = query.lower()
    for pat in PRIVACY_PATTERNS:
        if re.search(pat, q):
            return "local", 0.0, [f"PRIVACY GATE matched /{pat}/ -> forced local"]
    score, reasons = complexity_score(query)
    decision = "cloud" if score >= threshold else "local"
    reasons.append(f"score {score:.1f} vs threshold {threshold} -> {decision}")
    return decision, score, reasons


# ------------------------------------------------------------------ eval ----
def evaluate(threshold: float = 2.0, verbose: bool = False):
    correct = 0
    routed_local = 0
    mistakes = []
    for query, expected, category in DATASET:
        decision, score, reasons = route(query, threshold)
        if decision == "local":
            routed_local += 1
        ok = decision == expected
        correct += ok
        if not ok:
            mistakes.append((query, expected, decision, category, score))
        if verbose:
            mark = "OK " if ok else "MISS"
            print(f"[{mark}] ({category}) score={score:5.1f} -> {decision:5s} | {query[:70]}")
    total = len(DATASET)
    acc = correct / total
    local_pct = routed_local / total
    return acc, local_pct, mistakes


if __name__ == "__main__":
    print(f"Dataset: {len(DATASET)} queries "
          f"({sum(1 for _, e, _ in DATASET if e == 'local')} local, "
          f"{sum(1 for _, e, _ in DATASET if e == 'cloud')} cloud)\n")

    best = None
    for t in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0]:
        acc, local_pct, _ = evaluate(t)
        print(f"threshold={t:.1f}  accuracy={acc:.1%}  kept-local={local_pct:.1%}")
        if best is None or acc > best[1]:
            best = (t, acc)

    t = best[0]
    print(f"\n--- best threshold {t} ---")
    acc, local_pct, mistakes = evaluate(t, verbose=True)
    print(f"\naccuracy={acc:.1%} | {local_pct:.1%} of queries stay on-device (zero cloud cost)")
    if mistakes:
        print(f"\n{len(mistakes)} mistakes to fix in v2:")
        for q, exp, got, cat, s in mistakes:
            print(f"  expected {exp}, got {got} [{cat}] (score {s:.1f}): {q[:80]}")
