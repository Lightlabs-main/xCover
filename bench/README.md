# Benchmark corpus

`data/corpus.jsonl` — 229 labelled protocol-risk scenarios, each carrying a source
URL that was fetched and checked, not recalled. It is the grounding corpus the
pricing agent retrieves from (SPEC §5.2 step 2) and the labelled set the
confidence gate is calibrated against (§5.4).

| | Rows |
|---|---|
| `label: "loss"` — an incident that occurred | 148 |
| `label: "no_loss"` — a valid flaw disclosed, not exploited | 81 |
| Distinct protocols | 156 |
| Date range | 2020-06-28 → 2026-08-11 |

## Where the rows come from, and how they were checked

**Loss rows.** The incident list comes from the DefiLlama hacks dataset
(`https://api.llama.fi/hacks`), which supplies a date, a reported loss amount, a
classification and a technique per incident. That dataset carries no per-incident
citation, so a citation was located for each one on `rekt.news` and **fetched**:
a missing article answers HTTP 500, so a row exists only where a real article
answered 200 with a headline. The headline is then checked against the incident
name — `WOO X` paired with a `Woofi` article was rejected on that basis rather
than admitted. `tools/build_corpus.py` and `tools/probe.sh` do this; re-running
them reproduces the file.

**No-loss rows.** Judged-valid high and medium severity findings from public
Code4rena audit competitions in money-market and stablecoin protocols, pulled
through the GitHub API, so each row's `sourceUrl` is an addressable issue.
Findings labelled `unsatisfactory` are excluded. The no-loss label is
cross-checked rather than assumed: a protocol that appears in the incident
dataset is not a clean negative and is dropped. That check removed Revert Lend
and Wise Lending, both of which were later exploited.

## Limits of this corpus, stated plainly

- **The loss rows' text is assembled from dataset fields plus the cited
  headline.** Each article was fetched and confirmed to exist and to be about the
  named protocol; each was not read end to end and paraphrased. The row asserts
  only what the dataset and the headline support.
- **The no-loss rows are audit findings.** That is one specific way a risk can
  fail to become a loss — disclosed rather than exploited. It is *not* the same
  as a market situation that looked dangerous and resolved safely (a depeg that
  recovered, a market frozen in time). Those are the weaker part of the corpus
  and the calibration report must not claim otherwise.
- **Loss amounts are as reported by DefiLlama**, and reported figures for
  exploits are frequently revised.
- **Class balance is 65/35 toward losses.** Accuracy must therefore be read
  alongside refusal precision, never on its own.

## Leakage rule for scoring

The corpus is both the evidence the model retrieves from and the set it is scored
on. Scoring a scenario while its own row is retrievable would measure recall of
the answer, not judgement. Scoring is therefore leave-one-out: the scenario under
test is removed from the retrievable corpus before its assessment is requested,
and its `outcome`, `label` and `lossUsd` are never shown to the model.

## Reproducing

```bash
curl -sS https://api.llama.fi/hacks -o /tmp/hacks.json
python3 tools/candidates.py /tmp/hacks.json /tmp/candidates.json
xargs -a /tmp/slugs.txt -P 8 -I{} tools/probe.sh {} > /tmp/verified.tsv
python3 tools/build_corpus.py /tmp/verified.tsv /tmp/candidates.json data/corpus.jsonl
tools/fetch_c4.sh <contest-repos> && python3 tools/build_negatives.py /tmp/c4_findings.jsonl /tmp/candidates.json /tmp/negatives.jsonl
```

Citations are live third-party URLs. A row whose source stops resolving is a row
that has lost its evidence, and should be dropped rather than kept on the
strength of having once been checked.
