# Gemini calibration status — 2026-08-19

**Status: not calibrated.** No confidence threshold was derived and no full Gemini
corpus run was started.

## Corpus and offline gates

The candidate artifact is `corpus-gemini.jsonl`: 177 Code4rena judged findings from
14 protocol groups, with 76 protocol-level `loss` rows and 101 `no_loss` rows. The
loss label means that the protocol appears in the checked incident snapshot; it does
not claim that the individual finding caused that incident. `gemini-corpus-check.md`
is the reproducible offline report.

The prompt path exposes only a redacted mechanism, a high/medium risk band, an era,
and opaque evidence ids. It does not expose protocol names, labels, outcomes, URLs,
source-family markers, loss amounts, or raw finding text. Whole protocol groups are
held out during retrieval. Offline retrieval purity is 53.2% weighted mean, below
the 75% stop gate.

## Live gates

- Smoke: passed one scenario against `gemini-3.5-flash-lite`; two passes returned
  structured JSON, valid citations, and 1,726 input / 414 output tokens. Both local
  `.env` and `.env.example` now use the model Gemini identified as available.
- Earlier 152-row candidate: the first no-evidence control completed 12/20 before
  the free-tier quota returned HTTP 429. Its partial result was too label-pure
  (AUC 0.81; 10/12 at several illustrative cutoffs), so that candidate was rejected
  and expanded with Sturdy V1 and Tapioca DAO findings.
- Revised 177-row candidate: a six-row balanced no-evidence control completed 3/3
  per class, AUC 0.33, and 2/6 at 4,000–5,000 bp illustrative cutoffs. The same six
  rows with evidence completed with AUC 0.17 and 3/6 at those cutoffs. These samples
  are too small to certify calibration, and retrieval did not improve the signal.

Because the control evidence is small and non-improving, the run stopped here. The
temporary raw JSONL files remain outside the repository; no full paid run or
threshold derivation is claimed.
