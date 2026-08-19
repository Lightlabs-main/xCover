# Gemini corpus preflight

Status: **PASS**

- Corpus: `bench/data/corpus-gemini-scenario.jsonl`
- Rows: 71
- Labels: 15 loss / 56 no-loss
- Protocol groups: 54 (4 mixed-label protocol groups allowed)
- Source/article groups: 71
- Date range: 2021-01-30 through 2025-02-25
- Source family: Immunefi
- Retrieval coverage: 100.0% of rows have at least one neighbour
- Retrieval neighbours per scenario: 5
- Retrieval label purity: 73.2% weighted mean; 100.0% maximum
- Retrieval gate: weighted mean must be at most 75%

Each label is taken from the outcome described by the same Immunefi article as the scenario: realized loss versus a reported/fixed or mitigated case. No cross-source incident join is used.
The prompt path exposes only redacted mechanism text, risk band, era, and opaque evidence IDs; provenance and labels remain evaluation-only.

No offline leakage, schema, source-family, or retrieval-purity failures.
