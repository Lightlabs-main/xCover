# xCover AI pricing agent

This package serves the xCover dashboard and pricing API. The AI pricing agent
reads live X Layer and Aave V3 state, evaluates a covered USDT position, and
returns a signed price or refusal. It never moves pool funds or settles claims.

The service is one part of the product:

- the pricing service prepares the decision;
- `PricingRegistry` records the decision;
- `xCoverVault` opens the covered Aave V3 position; and
- `CoverPool` holds underwriting capital and pays valid claims.

## Calibration status

Pricing calibration is in progress. `provisional_pricing` is the current live
mode with explicit operating controls. `calibration_in_progress` starts a
refusal-only service while a new calibration run is prepared. No measured
confidence threshold is claimed until the evidence supports one.

## Start locally

From the workspace root:

```bash
pnpm --filter @xcover/pricing-agent build
set -a; source .env; set +a
XCOVER_ENVIRONMENT=mainnet \
PRICING_MODE=provisional_pricing \
PRICING_MODEL_PROVIDER=alibaba \
ALIBABA_MODEL=qwen-3.8-max-free \
HOST=127.0.0.1 PORT=8787 \
pnpm --filter @xcover/pricing-agent start
```

Open `http://127.0.0.1:8787/` for the landing page. Select **Open dashboard**
to connect a wallet and use the transaction flow.

## Decision endpoint

```bash
curl -X POST http://127.0.0.1:8787/decision \
  -H 'content-type: application/json' \
  -d '{"coverAmount":"50000000"}'
```

The response contains a canonical decision, signature, and decision hash. The
dashboard records the accepted decision before it enables a covered deposit.
Refusals are returned and recorded as decisions; they do not open positions.

## Tests and build

```bash
pnpm --filter @xcover/pricing-agent test
pnpm --filter @xcover/pricing-agent build
```

Runtime settings are described in [`.env.example`](../../.env.example). Pricing
state and calibration evidence are described in
[`docs/pricing-agent.md`](../../docs/pricing-agent.md) and [`bench`](../../bench).
