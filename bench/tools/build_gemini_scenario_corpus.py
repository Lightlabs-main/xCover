"""Build the Gemini corpus from Immunefi's scenario-level case reports.

The old Gemini candidate labelled Code4rena findings by whether their protocol
later appeared in an incident list.  This builder deliberately does not join
records across sources.  Each row is one Immunefi article and its label comes
from the outcome described in that article: a realized loss, or a reported bug
that the article says was fixed/mitigated before a realized loss.  Articles that
are tutorials, editorials, or general vulnerability education are excluded.

The downloaded HTML is an input, not model-facing data.  ``modelTitle`` is a
mechanism-only projection; source title, article text, URL, label, and outcome
remain available for audit but are never passed to the scorer.
"""

from __future__ import annotations

import argparse
import html
import json
import re
from collections import Counter
from pathlib import Path


EXCLUDED = {
    "common-cross-chain-bridge-vulnerabilities",
    "how-to-write-a-bugfix-review",
    "mev-attack-reproduction",
    "potential-impact-of-erc-777-tokens-on-defi-protocols",
    "setting-up-a-bridge-with-foundry",
    "subdomain-takeover-bugs-when-theyre-applicable-and-when-theyre-not",
    "the-potential-impact-of-erc-777-tokens-on-defi-protocols",
    "two-novel-crypto-wallet-exploits-explained",
    "weekly-bugfix-snapshot-march-29",
    "why-bugfix-reviews-are-good-for-web3",
}

# These pages explicitly describe a realized loss in the scenario covered by the
# article.  The remaining included Bug Fix Reviews are the prevented/mitigated class.
LOSS_SLUGS = {
    "88mph-theft-of-unclaimed-mph-rewards-bugfix-review",
    "cream-finance-insufficient-validation-bugfix-review",
    "mushrooms-finance-theft-of-yield-bugfix-review",
    "polygon-lack-of-balance-check-bugfix-review-2-2m-bounty",
    "sharedstake-insider-exploit-postmortem",
    "hack-analysis-0xbadc0de-mev-bot-september-2022",
    "hack-analysis-beanstalk-governance-attack-april-2022",
    "hack-analysis-binance-bridge-october-2022",
    "hack-analysis-bonqdao-february-2023",
    "hack-analysis-cream-finance-oct-2021",
    "hack-analysis-nomad-bridge-august-2022",
    "hack-analysis-omni-protocol-july-2022",
    "hack-analysis-saddle-finance-april-2022",
    "hack-analysis-the-hundred-finance-heist-march-2022",
    "hack-analysis-uranium-finance-april-2021",
}

PROTOCOLS = {
    "88mph": "88MPH",
    "alchemix": "Alchemix",
    "apwine": "APWine",
    "armor": "Armor",
    "astar-network": "Astar Network",
    "aurora": "Aurora",
    "aztec": "Aztec Network",
    "balancer": "Balancer",
    "beanstalk": "Beanstalk",
    "belt-finance": "Belt Finance",
    "bitswift": "Bitswift",
    "charged-particles": "Charged Particles",
    "cream-finance": "Cream Finance",
    "cronos": "Cronos",
    "dfx-finance": "DFX Finance",
    "enzyme-finance": "Enzyme Finance",
    "fei-protocol": "Fei Protocol",
    "hack-analysis-0xbadc0de": "0xbaDc0dE MEV Bot",
    "hack-analysis-beanstalk": "Beanstalk",
    "hack-analysis-binance": "Binance Bridge",
    "hack-analysis-bonqdao": "BonqDAO",
    "hack-analysis-cream": "Cream Finance",
    "hack-analysis-nomad": "Nomad Bridge",
    "hack-analysis-omni": "Omni Protocol",
    "hack-analysis-saddle": "Saddle Finance",
    "hack-analysis-the-hundred": "Hundred Finance",
    "hack-analysis-uranium": "Uranium Finance",
    "harvest-finance": "Harvest Finance",
    "mcdex": "MCDEX",
    "moonbeam": "Moonbeam",
    "mt-pelerin": "Mt Pelerin",
    "mushrooms-finance": "Mushrooms Finance",
    "notional": "Notional",
    "openzeppelin": "OpenZeppelin",
    "optimism": "Optimism",
    "pancakeswap": "PancakeSwap",
    "pods-finance": "Pods Finance",
    "polygon": "Polygon",
    "port-finance": "Port Finance",
    "raydium": "Raydium",
    "redacted-cartel": "Redacted Cartel",
    "rocketpool": "RocketPool",
    "sense-finance": "Sense Finance",
    "sharedstake": "SharedStake",
    "silo-finance": "Silo Finance",
    "sky": "Sky",
    "sovryn": "Sovryn",
    "stacks": "Stacks",
    "sui": "Sui",
    "synthetix": "Synthetix",
    "teller": "Teller",
    "the-graph": "The Graph",
    "threshold": "Threshold Network",
    "tidal-finance": "Tidal Finance",
    "vesper": "Vesper",
    "wormhole": "Wormhole",
    "xdai-stake": "xDai",
    "yield-protocol": "Yield Protocol",
    "zapper": "Zapper",
    "zksync": "zkSync",
}

ALIASES = sorted(
    {
        *PROTOCOLS.values(),
        "Astar",
        "Acala",
        "Lido Finance",
        "MakerDAO",
        "Agave",
        "Ethereum",
        "Binance",
    },
    key=len,
    reverse=True,
)

HACK_MECHANISMS = {
    "hack-analysis-0xbadc0de-mev-bot-september-2022": "insufficient flashloan caller validation and arbitrary function execution",
    "hack-analysis-beanstalk-governance-attack-april-2022": "missing execution delay in governance proposals",
    "hack-analysis-binance-bridge-october-2022": "insufficient IAVL Merkle proof verification",
    "hack-analysis-bonqdao-february-2023": "price oracle manipulation",
    "hack-analysis-cream-finance-oct-2021": "hybrid oracle manipulation and uncapped token supply",
    "hack-analysis-nomad-bridge-august-2022": "zero trusted root in bridge message verification",
    "hack-analysis-omni-protocol-july-2022": "reentrancy across collateral borrowing functions",
    "hack-analysis-saddle-finance-april-2022": "price calculation inconsistency in an automated market maker",
    "hack-analysis-the-hundred-finance-heist-march-2022": "reentrancy during collateral accounting",
    "hack-analysis-uranium-finance-april-2021": "incorrect constant product calculation in an automated market maker",
}

TAG_RE = re.compile(r"<[^>]+>", re.S)
PARAGRAPH_RE = re.compile(r"<p[^>]*>(.*?)</p>", re.I | re.S)
TITLE_RE = re.compile(r'<h1[^>]*class="[^"]*post-title[^>]*>(.*?)</h1>', re.I | re.S)
DATE_RE = re.compile(r'<meta[^>]+property="article:published_time"[^>]+content="([^"]+)', re.I)


def clean(value: str) -> str:
    value = re.sub(r"<script.*?</script>|<style.*?</style>", " ", value, flags=re.I | re.S)
    value = TAG_RE.sub(" ", value)
    value = html.unescape(value).replace("\\n", " ").replace('\\"', '"')
    return re.sub(r"\s+", " ", value).strip()


def protocol_for(slug: str) -> str:
    for prefix in sorted(PROTOCOLS, key=len, reverse=True):
        if slug.startswith(prefix):
            return PROTOCOLS[prefix]
    raise ValueError(f"no protocol mapping for {slug}")


def safe_mechanism(slug: str, title: str, summary: str, protocol: str) -> str:
    value = HACK_MECHANISMS.get(slug, title)
    if value == title:
        value = re.sub(r"\s*[—–-]?\s*\$[\d,.]+[a-zA-Z]*", "", value)
        value = re.sub(r"\b(?:bugfix review|bug fix review|postmortem|hack analysis|analysis)\b", " ", value, flags=re.I)
        for alias in ALIASES:
            value = re.sub(re.escape(alias), " ", value, flags=re.I)
        value = re.sub(r"\b(?:critical|high|medium|low)\b", " ", value, flags=re.I)
        value = re.sub(r"\b(?:loss|losses|lost|steal|stolen|drain|drained|exploit|exploited|hack|hacked|theft|funds?)\b", " ", value, flags=re.I)
    value = re.sub(r"\b(?:202[0-9]|20[0-9]{2})\b|\b\d+(?:\.\d+)?\b", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" -:;,.")
    if len(value) < 5:
        value = re.sub(r"\b(?:loss|losses|lost|steal|stolen|drain|drained|exploit|exploited|hack|hacked|theft|funds?)\b", " ", summary, flags=re.I)
        for alias in ALIASES:
            value = re.sub(re.escape(alias), " ", value, flags=re.I)
        value = re.sub(r"\s+", " ", value).strip(" -:;,." )
    return value or "unspecified mechanism"


def parse_page(path: Path) -> dict:
    slug = path.stem
    raw = path.read_text(encoding="utf-8")
    title_match = TITLE_RE.search(raw)
    date_match = DATE_RE.search(raw)
    if not title_match or not date_match:
        raise ValueError(f"missing title/date in {path.name}")
    content_match = re.search(r'<div class="content">(.*?)(?:<div class="share-block|</main>)', raw, re.I | re.S)
    if not content_match:
        raise ValueError(f"missing article body in {path.name}")
    paragraphs = [clean(match) for match in PARAGRAPH_RE.findall(content_match.group(1))]
    paragraphs = [paragraph for paragraph in paragraphs if paragraph]
    if not paragraphs:
        raise ValueError(f"missing article paragraphs in {path.name}")
    title = clean(title_match.group(1))
    protocol = protocol_for(slug)
    label = "loss" if slug in LOSS_SLUGS else "no_loss"
    summary = " ".join(paragraphs[:4])
    classification = "high" if re.search(r"\b(?:critical|high)\b", summary, re.I) else "medium"
    return {
        "id": f"immunefi-{slug}",
        "title": title,
        "sourceUrl": f"https://immunefi.com/blog/bug-fix-reviews/{slug}/",
        "publishedAt": date_match.group(1)[:10],
        "protocol": protocol,
        "outcome": summary,
        "text": " ".join(paragraphs),
        "label": label,
        "classification": classification,
        "technique": safe_mechanism(slug, title, summary, protocol),
        "sourceFamily": "Immunefi",
        "sourceGroup": slug,
        "modelTitle": safe_mechanism(slug, title, summary, protocol),
        "outcomeMethod": (
            "article explicitly describes realized loss in the reported scenario"
            if label == "loss"
            else "article is a Bug Fix Review describing responsible disclosure and remediation"
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    rows = []
    for path in sorted(args.pages_dir.glob("*.html")):
        if path.stem in EXCLUDED:
            continue
        if not re.search(r"(?:bugfix|hack-analysis|exploit-postmortem)", path.stem, re.I):
            continue
        rows.append(parse_page(path))
    rows.sort(key=lambda row: (row["publishedAt"], row["id"]))
    if len({row["sourceUrl"] for row in rows}) != len(rows):
        raise SystemExit("duplicate source URLs")
    if any(not row["modelTitle"] for row in rows):
        raise SystemExit("empty model title")
    args.out.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n", encoding="utf-8")
    print(json.dumps({"rows": len(rows), "labels": Counter(row["label"] for row in rows), "protocols": len({row["protocol"] for row in rows})}, default=dict))


if __name__ == "__main__":
    main()
