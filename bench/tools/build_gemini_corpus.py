"""Build the separate Gemini calibration corpus from Code4rena findings.

Both labels use the same source family and the same kind of source record: a judged
Code4rena issue.  The loss label is protocol-level: the protocol has a recorded loss
in the checked incident snapshot.  It does not claim that this particular finding
caused that loss.  That limitation is recorded in the corpus documentation and is
checked again before scoring.

The model-facing scorer must not use the protocol, outcome, URL, or raw body fields.
Those fields remain here only for auditability and post-run evaluation.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


LOSS_REPOS = {
    "2021-10-badgerdao-findings": "Badger DAO",
    "2022-04-badger-citadel-findings": "Badger DAO",
    "2022-06-badger-findings": "Badger DAO",
    "2023-10-badger-findings": "Badger DAO",
    "2022-05-alchemix-findings": "Alchemix V2",
    "2023-07-moonwell-findings": "Moonwell Lending",
    "2024-03-acala-findings": "Acala Network",
    "2022-05-sturdy-findings": "Sturdy V1",
    "2023-07-tapioca-findings": "Tapioca DAO",
}

NO_LOSS_REPOS = {
    "2022-09-frax-findings": "Frax",
    "2023-12-ethereumcreditguild-findings": "Ethereumcreditguild",
    "2024-03-abracadabra-money-findings": "Abracadabra Money",
    "2023-01-reserve-findings": "Reserve",
}


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def date_for(row: dict) -> str:
    created = row.get("createdAt")
    if created:
        return created[:10]
    match = re.match(r"(\d{4})-(\d{2})-", row["repo"])
    if not match:
        raise ValueError(f"cannot derive date for {row['repo']}#{row['number']}")
    return f"{match.group(1)}-{match.group(2)}-01"


def severity(labels: list[str]) -> str:
    if "3 (High Risk)" in labels:
        return "high"
    if "2 (Med Risk)" in labels:
        return "medium"
    raise ValueError(f"missing high/medium label: {labels}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--existing", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    existing = read_jsonl(args.existing)
    existing_no_loss = [row for row in existing if row.get("label") == "no_loss"]
    loss_outcomes = {
        row["protocol"]: row
        for row in existing
        if row.get("label") == "loss"
    }

    rows: list[dict] = []
    seen_urls: set[str] = set()
    for row in existing_no_loss:
        source_url = row["sourceUrl"]
        if source_url in seen_urls:
            continue
        seen_urls.add(source_url)
        copied = dict(row)
        copied["sourceFamily"] = "Code4rena"
        copied["outcomeMethod"] = "judged finding; no incident record in the checked snapshot"
        rows.append(copied)

    skipped = Counter()
    for finding in read_jsonl(args.manifest):
        repo = finding["repo"]
        protocol = LOSS_REPOS.get(repo) or NO_LOSS_REPOS.get(repo)
        if protocol is None:
            skipped[repo] += 1
            continue
        source_url = finding["url"]
        if source_url in seen_urls:
            continue
        seen_urls.add(source_url)
        label = "loss" if repo in LOSS_REPOS else "no_loss"
        incident = loss_outcomes.get(protocol)
        rows.append(
            {
                "id": f"c4-{repo}-{finding['number']}",
                "title": finding["title"],
                "sourceUrl": source_url,
                "publishedAt": date_for(finding),
                "protocol": protocol,
                "outcome": (
                    "protocol later appears in the checked incident snapshot"
                    if label == "loss"
                    else "no incident record found in the checked snapshot"
                ),
                "text": finding["title"],
                "label": label,
                "lossUsd": incident.get("lossUsd") if incident else 0,
                "classification": f"Code4rena finding ({severity(finding['labels'])} severity)",
                "technique": None,
                "chains": [],
                "targetType": "DeFi Protocol",
                "sourceFamily": "Code4rena",
                "outcomeMethod": (
                    "protocol matches a recorded incident in the checked snapshot"
                    if label == "loss"
                    else "protocol absent from the checked incident snapshot"
                ),
                "outcomeSourceUrl": incident.get("sourceUrl") if incident else None,
            }
        )

    rows.sort(key=lambda row: (row["publishedAt"], row["id"]))
    labels = Counter(row["label"] for row in rows)
    protocols = Counter((row["protocol"], row["label"]) for row in rows)
    if not 150 <= len(rows) <= 250:
        raise SystemExit(f"corpus size {len(rows)} is outside the required 150–250 range")
    if len({row["id"] for row in rows}) != len(rows):
        raise SystemExit("duplicate ids")
    if len({row["sourceUrl"] for row in rows}) != len(rows):
        raise SystemExit("duplicate source URLs")
    if any(len({label for (protocol, label), count in protocols.items() if protocol == p}) > 1 for p in {p for p, _ in protocols}):
        raise SystemExit("a protocol appears under both labels")

    args.out.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n")
    print(json.dumps({"rows": len(rows), "labels": labels, "protocols": len({row['protocol'] for row in rows}), "skippedRepos": skipped}, default=dict))


if __name__ == "__main__":
    main()
