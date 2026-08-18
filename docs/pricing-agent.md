# Pricing-agent configuration and handoff

This file resolves a common source of confusion: the specification defines the
agent's behavior, but not every deployment parameter. A value must not be
described as “from the spec” when it is actually a runtime choice or a result of
benchmark calibration.

## What the specification defines

- The read → retrieve → assess → compute → gate pipeline (§5.2).
- Two differently framed model assessments, with disagreement treated as a
  measured signal.
- Deterministic code controls the final premium and every money-moving action.
- Refusal is signed, hashed, recorded, and publicly replayable.
- The contract's `deficitFloorBps` is 50 bp.
- The contract's `depegLowerBound` is `97_000_000` at 8 oracle decimals.
- The calibration corpus must contain 150–250 labelled scenarios and the
  confidence threshold must be derived from its calibration curve (§5.4).

## What is configuration or still outstanding

| Setting/artifact | Classification | Current status |
|---|---|---|
| `ANTHROPIC_MODEL` | Provider configuration | `claude-opus-5`, verified live: present in `GET /v1/models` and exercised through `assess()` |
| `XCOVER_ENVIRONMENT` | Deployment selection | Must be `testnet` or `mainnet`; the loader checks the live venue |
| `PRICING_ENGINE_VERSION` | Decision metadata | Set to `pricing-1.0.0/xlayer-usdt` in the example |
| `QUOTE_TTL_BLOCKS` | Runtime policy | Exact value is not specified by §5; review before mainnet |
| `bench/data/corpus.jsonl` | Required evidence artifact | **Created — 229 cited labelled scenarios, every citation fetched and checked.** Sound as an artifact; unusable for calibration, for the structural reason in `bench/README.md`. |
| Confidence threshold | Calibration output | **Not derived, and not derivable from the current corpus** — the signal failed calibration and the benchmark's accuracy proved to be an artifact. Any value set here is an operator choice and must be labelled as one. See `bench/threshold-derivation.md`. |
| Ensemble disagreement bound | Calibration/review output | **Measured**: mean 993 bp, p90 2,000 bp, max 3,000 bp over 228 scenarios |
| Uncertainty-loading bound | Calibration/review output | **Measured**: mean 4,532 bp, p90 6,000 bp, max 7,000 bp over 228 scenarios |
| Capital-cost margin | Underwriting policy | Not specified; must be reviewed |
| Oracle age/deviation bounds | Chain-risk policy | Not specified; must be reviewed |
| Maximum premium rate | Deterministic safety ceiling | Not specified; must be reviewed |

`PRICING_DEPEG_LOWER_BOUND_8DP=97000000` is not outstanding: it is the
spec-defined contract term. `QUOTE_TTL_SECONDS` is retained for compatibility,
but the on-chain decision is block-based, so production runs should provide
`QUOTE_TTL_BLOCKS` explicitly (or provide a reviewed block-time conversion).

## The model call

The assessment request is made with the official Anthropic SDK rather than a
hand-rolled HTTP body, because the hand-rolled one had already drifted: it sent
`temperature`, which the current models reject outright. The request carries no
sampling parameters, uses adaptive thinking at `high` effort, and treats a
safety refusal or a truncated response as a failed assessment rather than
parsing a number out of an incomplete answer.

Evidence ids are checked against the retrieved corpus plus one reserved id,
`live-chain-state`, for facts read directly from the chain. That id is not a
loophole: the state it refers to is committed verbatim to the decision document
at a named block, so a reader can re-read it, and an empty corpus is still
refused by the gate before any assessment can stand on chain state alone.
Without it, an assessment that correctly grounded a hazard factor in live state
was rejected wholesale — observed against the live model, which cited exactly
that id unprompted.

## Current chain constraint

The corrected testnet deployment has a residual 2,500 tUSDT reserve deficit from
the completed payout rehearsal. The agent must refuse while that deficit is
non-zero. A live agent-signed quote therefore requires a fresh clean testnet
venue or the later mainnet deployment; changing a threshold cannot override this
gate.

## Next sequence

1. ~~Assemble and cite `bench/data/corpus.jsonl`.~~ Done — 229 rows.
2. ~~Score it and publish the calibration/threshold derivation.~~ Done, and the
   result is negative: no threshold is derivable. Do not re-run it; see
   `HANDOFF.md` §4a before spending anything further.
3. Review the non-benchmark runtime controls listed above.
4. Set `XCOVER_ENVIRONMENT` and add the reviewed values in `.env`.
5. Run the agent against a clean eligible venue, then record one quote and one
   refusal through the real `PricingRegistry` path.
