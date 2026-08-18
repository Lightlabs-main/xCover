"""Materialise the no-loss side of the corpus from judged-valid Code4rena findings.

A row here is a protocol-risk situation with a known outcome: a valid high or medium
severity flaw in a money-market or stablecoin protocol that was disclosed through a
public audit competition rather than exploited. The "no loss" label is not taken on
trust — the protocol is cross-checked against the incident dataset, and a protocol that
does appear there is dropped rather than presented as a clean negative.
"""
import json, re, sys, collections

PER_CONTEST = 7

def protocol_of(repo):
    name = re.sub(r"^\d{4}-\d{2}-", "", repo)
    name = re.sub(r"-(findings|mitigation-contest|mitigation)$", "", name)
    return name.replace("-", " ").title()

findings = [json.loads(l) for l in open(sys.argv[1])]
incidents = json.load(open(sys.argv[2]))
hacked = {re.sub(r"[^a-z0-9]", "", i["name"].lower()) for i in incidents}

def was_hacked(protocol):
    key = re.sub(r"[^a-z0-9]", "", protocol.lower())
    return any(key and (key in h or h in key) and min(len(key), len(h)) >= 5 for h in hacked)

rows, dropped, per = [], collections.Counter(), collections.Counter()
# Highest-signal findings first: a judged, report-selected high-risk issue is a stronger
# scenario than a borderline one.
def rank(f):
    labels = set(f["labels"])
    return (
        "selected for report" in labels,
        "sponsor confirmed" in labels,
        "3 (High Risk)" in labels,
    )

for finding in sorted(findings, key=rank, reverse=True):
    protocol = protocol_of(finding["repo"])
    if was_hacked(protocol):
        dropped[protocol] += 1
        continue
    if per[finding["repo"]] >= PER_CONTEST:
        continue
    per[finding["repo"]] += 1
    severity = "high" if "3 (High Risk)" in finding["labels"] else "medium"
    when = finding["createdAt"][:10]
    rows.append({
        "id": f"audit-{finding['repo'].replace('-findings','')}-{finding['number']}",
        "title": finding["title"][:160],
        "sourceUrl": finding["url"],
        "publishedAt": when,
        "protocol": protocol,
        "outcome": "disclosed in a public audit competition; no depositor loss recorded",
        "text": (
            f"{protocol}, {when}. A {severity}-severity flaw judged valid in a public Code4rena "
            f"audit competition: {finding['title']}. It was disclosed and judged rather than "
            f"exploited, and no incident against {protocol} appears in the incident dataset. "
            f"Judge labels: {', '.join(finding['labels'])}."
        ),
        "label": "no_loss",
        "lossUsd": 0,
        "classification": f"Audit finding ({severity} severity)",
        "technique": None,
        "chains": [],
        "targetType": "DeFi Protocol",
    })

with open(sys.argv[3], "w") as handle:
    for row in sorted(rows, key=lambda r: r["publishedAt"]):
        handle.write(json.dumps(row) + "\n")
print(f"{len(rows)} no-loss rows across {len(per)} competitions")
print("dropped as not-a-clean-negative (protocol appears in the incident dataset):", dict(dropped))
