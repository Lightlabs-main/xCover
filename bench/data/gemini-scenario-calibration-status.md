# Gemini scenario-level calibration status

Date: 2026-08-19

## Result

**Stopped at the evidence control. No full Gemini calibration was run and no
confidence threshold was derived.**

The previous Code4rena candidate was discarded for this purpose: its loss label
was inherited from a later protocol incident, not from the finding under test.
This replacement uses one Immunefi article per scenario and takes the label from
that article's own case outcome. It contains 71 rows: 15 realized-loss cases and
56 reported/fixed or mitigated cases. Mixed labels for the same protocol are
allowed; the entire protocol and the entire source article are held out of
retrieval for every scored row.

## Offline gate

`gemini-scenario-corpus-check.md` is **PASS**.

- 71 rows, 15 loss / 56 no-loss.
- 71 source/article groups and 54 protocol groups.
- 100% retrieval coverage using five neighbours per scenario.
- 73.2% weighted retrieval label purity, below the 75% stop gate.
- No model-facing label, outcome, provenance, protocol, or source-family leak.

The five-neighbour budget is fixed in both controls. It was selected before live
scoring because the twelve-neighbour default exceeded the offline purity gate;
the live controls were not re-sampled or tuned after seeing their results.

## Live controls

Both runs used `gemini-3.5-flash-lite`, two framings, one worker, and the exact
same balanced 20-row sample: 10 loss and 10 no-loss. Error rows are not counted;
both runs completed 20/20 with zero errors.

| Run | Evidence | AUC | Directional accuracy at 5,000 bp | Mean confidence | Input / output tokens |
|---|---:|---:|---:|---:|---:|
| No-evidence control | 0 | 0.635 | 13/20 (65%) | 265 bp | 15,712 / 7,168 |
| Evidence control | 5 | 0.615 | 11/20 (55%) | 2,450 bp | 26,852 / 8,977 |

The no-evidence gate passed its predeclared stop rule: stop for a material framing
signal at AUC above 0.70 or more than 15/20 directionally correct. The evidence
gate failed: retrieval lowered AUC by 0.020 and directional accuracy by two rows,
so it did not improve judgement. The offline purity check passing is not enough
to claim that evidence helps in the live task.

Raw runs:

- `scores-gemini-scenario-noevidence.jsonl`
- `scores-gemini-scenario-evidence.jsonl`
- `scores-gemini-scenario-smoke.jsonl`

## Next step

Do not run the 71-row calibration or populate
`PRICING_CONFIDENCE_THRESHOLD_BPS`. The next iteration needs a stronger
same-source control design whose evidence improves the fixed balanced sample;
more Gemini calls against this corpus would not answer that question.
