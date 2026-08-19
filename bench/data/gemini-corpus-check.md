# Gemini corpus preflight

Status: **PASS**

- Corpus: `bench/data/corpus-gemini.jsonl`
- Rows: 177
- Labels: 76 loss / 101 no-loss
- Protocol groups: 14 (each group has one label)
- Date range: 2021-07-13 through 2024-08-19
- Source family: Code4rena judged findings only
- Retrieval coverage: 100.0% of rows have at least one neighbour
- Retrieval label purity: 53.2% weighted mean; 100.0% maximum
- Retrieval gate: weighted mean must be at most 75%

The loss label is protocol-level: a protocol appears in the checked incident snapshot. It does not assert that the individual finding caused that incident. The prompt path exposes only redacted mechanism text, risk band, era, and opaque evidence IDs; provenance and labels remain evaluation-only.

No offline leakage, schema, source-family, or retrieval-purity failures.
