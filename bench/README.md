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

## Scoring status

A 20-scenario balanced pilot separated the two classes completely — mean loss
likelihood 8,692 bp against 515 bp, 20 of 20 directionally correct. That is too
clean to accept at face value. The two halves of this corpus are written in
different words, and a model that reads the wording rather than the risk would
produce exactly this result. `bench/score.mts` neutralises the obvious markers
(`- REKT` suffixes, `Audit finding (…)` classifications) and reduces both halves
to the same three fields, but narrowing a leak is not the same as closing it.

The test is the control run — the same scenarios with retrieval disabled
(`--noEvidence`). If accuracy survives with no evidence to reason from, the
benchmark is measuring the framing and no accuracy figure from it may be
published. That run is outstanding: it stopped on an Anthropic API credit limit.

**No gate threshold is derived from this corpus yet, and none should be until
the control has run.**

---

# Result: this corpus cannot support the §5.4 calibration

**Do not run more scoring against this corpus expecting a usable threshold.** Three
measurements, run 18 August 2026, establish that every route to high accuracy on it is
an artifact of how it was built. The raw per-scenario output for all three is committed
alongside this file.

| Experiment | Scenario shows | Evidence retrieved | Accuracy | Data |
|---|---|---|---|---|
| 1 | protocol name + date | none | **17/20** | `data/control-sonnet5-low.jsonl` |
| 2 | era + mechanism only | none | **12/20** | `data/control-anon.jsonl` |
| 3 | era + mechanism only | 12 entries, whole protocol held out | **54/54** | `data/anon-evidence-60.jsonl` |

Chance is 50%.

**Experiment 1 — the model recognises the protocols.** With every piece of evidence
removed it still scored 17/20, because it knows Balancer and Yearn were exploited. Naming
the protocol hands over the answer.

**Experiment 2 — removing the name closes that.** Anonymising the scenario to an era and a
mechanism drops it to 12/20, which for n=20 is not distinguishable from guessing. Class
separation collapsed with it: mean loss likelihood went from 7,760/4,115 bp to 5,800/4,475.

**Experiment 3 — but then retrieval hands the answer over instead.** 54/54 looks like
retrieval doing real work. It is not. **99.8% of the evidence actually retrieved carries
the scenario's own label** (99.7% for loss rows, 100.0% for no-loss rows), and every row's
`outcome` field states the answer in words:

```
loss     ->  "loss of 500,000,000,000 USD"
no_loss  ->  "disclosed in a public audit competition; no depositor loss recorded"
```

The model reads twelve neighbours that all say the same thing and copies them. That is
nearest-neighbour label propagation, not judgement.

## Why this is structural, not a tuning problem

The two halves of the corpus come from different source types — incident write-ups from
`rekt.news`, audit findings from Code4rena — and they are written in different vocabulary.
Lexical retrieval therefore returns a same-class neighbourhood essentially every time. No
amount of holding out protocols, anonymising fields, or re-running fixes that, because the
separability is in the source material.

**What a usable corpus needs: negatives drawn from the same source type and written in the
same words as the positives.** For example, protocols with a comparable profile over a
comparable period that were not exploited, described in the same terms as the ones that
were. Neither source used here can produce that, which is why this is a rebuild of the
corpus's *sources*, not of its formatting.

## Cost model, measured — do not project one run type from another

This is the mistake that cost the most here. A no-evidence control run has prompts roughly
6.5× smaller than a real run, so projecting a with-evidence cost from a control understates
it by more than half.

| Run type | Input/scenario | Output/scenario | Cost/scenario (Sonnet 5, `effort: low`) |
|---|---|---|---|
| With evidence (12 entries) | ~7,170 tok | ~1,549 tok | **$0.030** |
| Control, no evidence | ~1,100 tok | ~1,050 tok | **$0.013** |

A full 229-row scored run with evidence is therefore about **$6.80**, and a 20-scenario
control about **$0.25**. `bench/score.mts` now prints actual spend after every run and
refuses to project a full-run cost from a no-evidence run.

Total spent establishing the above: **$9.00**.
