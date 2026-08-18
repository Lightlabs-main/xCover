"""Build rekt.news slug candidates for the incidents named in the DefiLlama hacks dataset.

The incident list is not invented: it comes from a public dataset with a date, a loss
amount, a classification and a technique per row. This script only proposes where the
citation for each of those incidents might live. Whether the citation exists is decided
by fetching it, never by assuming the slug is right.
"""
import json, re, sys, datetime

RELEVANT_CLASSES = {
    "Oracle Manipulation", "Token & Share Accounting", "Protocol Logic",
    "Market Manipulation", "Governance", "Input Validation", "Reentrancy",
}

def slugs(name: str):
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    base = re.sub(r"-(v[0-9]+|core|pool|protocol|finance|lending|perps)$", "", base)
    out = [f"{base}-rekt", f"{base}-rekt-2", f"{base}-rekt-3"]
    first = base.split("-")[0]
    if first != base:
        out += [f"{first}-rekt", f"{first}-rekt-2"]
    return list(dict.fromkeys(out))

rows = json.load(open(sys.argv[1]))
seen, out = set(), []
for r in rows:
    year = datetime.datetime.fromtimestamp(r["date"], datetime.UTC).year
    if year < 2020 or r.get("targetType") not in ("DeFi Protocol", "Token", "Chain", "Liquidity Pool"):
        continue
    if r["classification"] not in RELEVANT_CLASSES:
        continue
    if r["name"] in seen:
        continue
    seen.add(r["name"])
    out.append({
        "name": r["name"], "date": r["date"], "amount": r["amount"],
        "classification": r["classification"], "technique": r.get("technique"),
        "chain": r.get("chain"), "slugs": slugs(r["name"]),
    })
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(f"{len(out)} candidate incidents, {sum(len(c['slugs']) for c in out)} slugs to probe")
