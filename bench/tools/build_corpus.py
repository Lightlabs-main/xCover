"""Materialise verified incident rows for bench/data/corpus.jsonl.

Every field is either copied from the DefiLlama hacks dataset (date, loss amount,
classification, technique, chain) or from the fetched rekt.news article (URL, headline).
Nothing here is written from memory: if the citation did not resolve, the incident does
not become a row, and if the article headline does not agree with the incident name, the
pairing is rejected rather than guessed at.
"""
import json, re, sys, datetime

STOP = {"finance", "protocol", "network", "capital", "labs", "dao", "money", "the", "v1", "v2", "v3", "core", "pool", "lending", "rekt", "swap"}

def tokens(text):
    return {t for t in re.split(r"[^a-z0-9]+", text.lower()) if t and t not in STOP and len(t) > 2}

def squash(text):
    return re.sub(r"[^a-z0-9]+", "", text.lower())

def agrees(name, headline):
    if tokens(name) & tokens(headline):
        return True
    # "COLDCARD" and "Cold Card" are the same target; "WOO X" and "Woofi" are not. Compare
    # the squashed forms so spacing does not lose a row, but require a real containment.
    a, b = squash(name), squash(headline.replace("REKT", "").replace("Rekt", ""))
    return len(a) >= 5 and len(b) >= 5 and (a in b or b in a)

verified = {}
for line in open(sys.argv[1]):
    slug, _, headline = line.rstrip("\n").partition("\t")
    if slug and headline:
        verified.setdefault(slug, headline.strip())

incidents = json.load(open(sys.argv[2]))
rows, rejected = [], []
for incident in incidents:
    for slug in incident["slugs"]:
        headline = verified.get(slug)
        if not headline:
            continue
        if not agrees(incident["name"], headline):
            rejected.append((incident["name"], slug, headline))
            continue
        when = datetime.datetime.fromtimestamp(incident["date"], datetime.UTC).date().isoformat()
        chains = ", ".join(incident.get("chain") or []) or "unspecified chain"
        amount = incident.get("amount")
        loss = f"{round(amount * 1_000_000):,} USD" if amount else "an undisclosed amount"
        technique = incident.get("technique") or "an unclassified technique"
        rows.append({
            "id": f"incident-{slug}",
            "title": headline,
            "sourceUrl": f"https://rekt.news/{slug}",
            "publishedAt": when,
            "protocol": incident["name"],
            "outcome": f"loss of {loss}",
            "text": (
                f"{incident['name']} on {chains}, {when}. Classification: {incident['classification']}. "
                f"Technique: {technique}. Reported depositor and protocol loss: {loss}. "
                f"Cited write-up: {headline}."
            ),
            "label": "loss",
            "lossUsd": round(amount * 1_000_000) if amount else None,
            "classification": incident["classification"],
            "technique": technique,
            "chains": incident.get("chain") or [],
            "targetType": incident.get("targetType"),
        })
        break

by_id = {row["id"]: row for row in rows}
with open(sys.argv[3], "w") as handle:
    for row in sorted(by_id.values(), key=lambda r: r["publishedAt"]):
        handle.write(json.dumps(row) + "\n")
print(f"{len(by_id)} rows written; {len(rejected)} slug/name pairings rejected")
for item in rejected[:8]:
    print("  rejected:", item)
