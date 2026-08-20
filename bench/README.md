# Pricing evidence

This directory contains the evidence used to evaluate xCover pricing. It is an
engineering record, not user-facing product copy. Raw inputs, outputs, source
checks, and scoring results remain in the repository so a reviewer can reproduce
the work.

## Current status

Pricing calibration is in progress. The main corpus contains 229 labelled
scenarios with cited source material:

| Measure | Value |
|---|---:|
| Scenarios | 229 |
| Incident scenarios | 148 |
| Non-incident findings | 81 |
| Distinct protocols | 156 |
| Source date range | 2020-06-28 to 2026-08-11 |

The corpus is fully assembled and its source URLs were fetched and checked. The
current scoring work did not produce a measured confidence threshold. That
result is preserved in the raw scoring files and
[`threshold-derivation.md`](threshold-derivation.md).

## Evidence rules

- Each scenario keeps an addressable source URL.
- The scenario under test is removed from retrieval before scoring.
- Labels, outcomes, and loss amounts are not shown to the pricing service as
  hidden answer fields.
- Incident and non-incident sources are checked separately because they use
  different language and describe different evidence.
- A source that stops resolving is removed rather than silently retained.

## Corpus construction

Loss rows begin with the public incident dataset and are checked against an
addressable incident report. Non-incident rows come from public audit findings
that were reviewed as valid findings without a recorded loss in the checked
material. The construction tools are in `tools/` and the source rows are in
`data/corpus.jsonl`.

Rebuild the primary corpus with:

```bash
curl -sS https://api.llama.fi/hacks -o /tmp/hacks.json
python3 tools/candidates.py /tmp/hacks.json /tmp/candidates.json
xargs -a /tmp/slugs.txt -P 8 -I{} tools/probe.sh {} > /tmp/verified.tsv
python3 tools/build_corpus.py /tmp/verified.tsv /tmp/candidates.json data/corpus.jsonl
```

## Preserved records

- `data/corpus.jsonl` - primary cited corpus;
- `data/control-*.jsonl` - no-evidence controls;
- `data/scores-*.jsonl` - raw scoring output;
- `data/*-corpus-check.md` - source and leakage checks;
- `data/*-calibration-status.md` - dated run decisions; and
- `threshold-derivation.md` - contract and pricing parameter provenance.

Historical run files retain their original names so their checksums and links
remain stable. They are evidence records, not current product configuration.

## Reproducibility requirements

A future calibration run must preserve the exact scenario set, retrieval rules,
service configuration, raw output, scoring script, and final decision. A
threshold may be published only with its supporting run and measurement.
