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
| `ANTHROPIC_MODEL` | Provider configuration | Set to `claude-3-5-sonnet-20241022` for the current direct API configuration |
| `XCOVER_ENVIRONMENT` | Deployment selection | Must be `testnet` or `mainnet`; the loader checks the live venue |
| `PRICING_ENGINE_VERSION` | Decision metadata | Set to `pricing-1.0.0/xlayer-usdt` in the example |
| `QUOTE_TTL_BLOCKS` | Runtime policy | Exact value is not specified by §5; review before mainnet |
| `bench/data/corpus.jsonl` | Required evidence artifact | Not created; 150–250 cited labelled scenarios are still needed |
| Confidence threshold | Calibration output | Not derived |
| Ensemble disagreement bound | Calibration/review output | Not derived |
| Uncertainty-loading bound | Calibration/review output | Not derived |
| Capital-cost margin | Underwriting policy | Not specified; must be reviewed |
| Oracle age/deviation bounds | Chain-risk policy | Not specified; must be reviewed |
| Maximum premium rate | Deterministic safety ceiling | Not specified; must be reviewed |

`PRICING_DEPEG_LOWER_BOUND_8DP=97000000` is not outstanding: it is the
spec-defined contract term. `QUOTE_TTL_SECONDS` is retained for compatibility,
but the on-chain decision is block-based, so production runs should provide
`QUOTE_TTL_BLOCKS` explicitly (or provide a reviewed block-time conversion).

## Current chain constraint

The corrected testnet deployment has a residual 2,500 tUSDT reserve deficit from
the completed payout rehearsal. The agent must refuse while that deficit is
non-zero. A live agent-signed quote therefore requires a fresh clean testnet
venue or the later mainnet deployment; changing a threshold cannot override this
gate.

## Next sequence

1. Assemble and cite `bench/data/corpus.jsonl`.
2. Score it and publish the calibration/threshold derivation.
3. Review the non-benchmark runtime controls listed above.
4. Verify `ANTHROPIC_MODEL=claude-3-5-sonnet-20241022`, set
   `XCOVER_ENVIRONMENT`, and add the reviewed values in `.env`.
5. Run the agent against a clean eligible venue, then record one quote and one
   refusal through the real `PricingRegistry` path.
