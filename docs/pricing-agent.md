# xCover AI pricing agent

The AI pricing agent reads live X Layer and Aave V3 state, retrieves cited risk
evidence, evaluates a covered position, and returns a signed price or a signed
refusal. It does not hold pool funds, open positions, or settle claims. The
connected wallet and contracts perform every money-moving action.

## Current status

Pricing calibration is in progress. The live service runs with
`PRICING_MODE=provisional_pricing`: chain reads, decision validation, signatures,
and registry recording are live, while the operating controls are explicitly
configured. No measured confidence threshold is claimed yet.

`PRICING_MODE=calibration_in_progress` is available for refusal-only operation
while a calibration run is being prepared. In live operation, a position is
priced only when the required reserve data, pool capacity, and decision checks
are available.

## Decision flow

1. Read the configured X Layer deployment and current Aave V3 reserve state.
2. Retrieve relevant evidence from the committed corpus.
3. Produce two independent assessments of the current position.
4. Compute the per-block price in deterministic code.
5. Apply reserve, capacity, freshness, and policy checks.
6. Return a canonical decision and signature.
7. Let the dashboard record the decision in `PricingRegistry`.

The vault accepts a covered deposit only after a valid accepted decision has
been recorded. A refusal is recorded in the same public path and cannot open a
covered position.

## Mainnet data boundary

On X Layer mainnet, reserve data comes from the deployed Aave V3 venue and its
aggregate oracle. The service uses the verified deployment record and does not
invent freshness data that the oracle does not provide. `ClaimResolver` remains
the authoritative path for sampled claim conditions.

## Configuration

The loader requires:

- `XCOVER_ENVIRONMENT`: `testnet` or `mainnet`;
- `PRICING_MODE`: the live mode or refusal-only calibration mode;
- `PRICING_MODEL_PROVIDER` and its configured endpoint credentials;
- `PRICER_PRIVATE_KEY`: signs prices and refusals; and
- reviewed bounds for confidence, disagreement, uncertainty, capital cost,
  oracle conditions, premium, and quote lifetime.

The current free calibration route is configured with:

```bash
PRICING_MODEL_PROVIDER=alibaba
ALIBABA_MODEL=qwen-3.8-max-free
```

Keep credentials in `.env`. Never commit them or print them in logs.

## Start the service

```bash
set -a; source .env; set +a
XCOVER_ENVIRONMENT=mainnet \
PRICING_MODE=provisional_pricing \
PRICING_MODEL_PROVIDER=alibaba \
ALIBABA_MODEL=qwen-3.8-max-free \
HOST=127.0.0.1 PORT=8787 \
pnpm --filter @xcover/pricing-agent start
```

Request a decision with a base-unit amount:

```bash
curl -X POST http://127.0.0.1:8787/decision \
  -H 'content-type: application/json' \
  -d '{"coverAmount":"50000000"}'
```

The response contains the signed decision, its hash, and the canonical decision
document. The dashboard uses those values to present the price and record it.

## Calibration evidence

The committed corpus contains 229 cited scenarios. The evidence and raw scoring
outputs remain in [`bench`](../bench). Current results show that the corpus does
not support a measured confidence threshold, so calibration remains in progress
and the threshold is not presented as a derived value.

The next calibration run must use a clean, held-out scenario set and preserve
the raw input, output, configuration, and scoring record.
