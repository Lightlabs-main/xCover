# xCover pricing agent

This service observes the configured X Layer deployment, retrieves matching
entries from the committed benchmark corpus, asks the configured model provider
for two cited risk assessments, computes a per-block rate in deterministic code,
applies refusal gates, and signs a `PricingRegistry.Decision` with EIP-712.

Supported providers are `anthropic` (the Anthropic SDK) and `gemini` (Google's
official `@google/genai` SDK with server-side structured JSON output). Select one
with `PRICING_MODEL_PROVIDER`; the provider's API key and model are then read
from the corresponding `ANTHROPIC_*` or `GEMINI_*` variables. Provider selection
is explicit so a Gemini key cannot be silently ignored by an Anthropic run.

The service never submits a transaction and never receives a pool, vault, or
claim role. A caller submits the returned `decision` and `signature` to
`PricingRegistry.recordDecision`. Both quotes and refusals are signed and
replayable at `GET /decision/:hash`.

Required runtime configuration is documented in the root `.env.example` and the
parameter provenance is recorded in [`docs/pricing-agent.md`](../../docs/pricing-agent.md).
`XCOVER_ENVIRONMENT` is mandatory. The loader reads the matching committed
deployment record and checks the live venue before opening a route. Pricing
thresholds are intentionally required configuration. The current corpus was
scored, but its confidence signal failed calibration; no calibrated confidence
threshold exists. Any value supplied to start the service is an operator choice
and must be labelled as such. The existing benchmark used `claude-sonnet-5` at
low effort and therefore does not calibrate an Opus 5 deployment.

From the workspace root, after the corpus and thresholds exist, load `.env` into
the process environment and select the provider explicitly:

```bash
set -a; source .env; set +a
XCOVER_ENVIRONMENT=testnet PRICING_MODEL_PROVIDER=gemini pnpm --filter @xcover/pricing-agent start
```

Request a decision with a decimal base-unit amount:

```bash
curl -X POST http://127.0.0.1:8787/decision \
  -H 'content-type: application/json' \
  -d '{"coverAmount":"50000000"}'
```

The current corrected testnet venue has a residual reserve deficit from the
completed payout rehearsal. A live request there must therefore return a signed
`DECLINE_TO_QUOTE` until a clean eligible venue state is available.
