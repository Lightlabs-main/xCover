# xCover pricing agent

This service observes the configured X Layer deployment, retrieves matching
entries from the committed benchmark corpus, asks Anthropic for two cited risk
assessments (via the official SDK; `claude-opus-5`), computes a per-block rate in deterministic code, applies refusal
gates, and signs a `PricingRegistry.Decision` with EIP-712.

The service never submits a transaction and never receives a pool, vault, or
claim role. A caller submits the returned `decision` and `signature` to
`PricingRegistry.recordDecision`. Both quotes and refusals are signed and
replayable at `GET /decision/:hash`.

Required runtime configuration is documented in the root `.env.example` and the
parameter provenance is recorded in [`docs/pricing-agent.md`](../../docs/pricing-agent.md).
`XCOVER_ENVIRONMENT` is mandatory. The loader reads the matching committed
deployment record and checks the live venue before opening a route. Pricing
thresholds are intentionally required configuration: they must come from the
benchmark calibration rather than guessed defaults.

From the workspace root, after the corpus and thresholds exist:

```bash
XCOVER_ENVIRONMENT=testnet pnpm --filter @xcover/pricing-agent start
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
