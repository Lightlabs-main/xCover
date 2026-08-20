# xCover

AI pricing agent for Aave V3 depositor cover on X Layer.

xCover reads live Aave V3 reserve state, evaluates the risk of a USDT position,
and returns a signed price or refusal. A depositor can then supply USDT through
xCover and open a covered position in the same flow. The position is backed by
a USDT underwriting pool: capital providers add funds, receive pool shares, and
supply the capital that stands behind depositor cover.

Read the complete product and architecture guide in
[`docs/project-guide.md`](docs/project-guide.md).

## The product

### For Aave V3 depositors

1. Connect a wallet on X Layer.
2. Request a live cover price for the USDT position.
3. Record the signed price.
4. Approve USDT and open the covered deposit.

The dashboard reads the reserve, shows the price, and keeps the final deposit
step tied to the recorded decision. A covered position can be read and exited
from the connected wallet.

### For underwriters

1. Approve USDT for the pool.
2. Add capital and receive pool shares.
3. Track total capital, active cover, and free capital.
4. Withdraw shares when the pool has enough free capital.

Premium from active positions returns to the pool. The pool enforces full
backing: capital must always cover the amount promised to open positions.

## How the AI pricing agent works

The AI pricing agent reads live X Layer and Aave V3 data, retrieves cited risk
evidence, evaluates the current reserve state, and returns a signed price or a
signed refusal. The contracts record every decision before a covered deposit can
open.

Pricing calibration is in progress. The live service uses explicit operating
controls while the measured threshold is being established. It can refuse to
price a position when the required reserve data or pool capacity is unavailable.

The contracts, rather than the AI pricing agent, control every money movement:

- `CoverPool` holds underwriting capital and tracks free capital;
- `xCoverVault` supplies the covered deposit to Aave V3 and creates the position;
- `PricingRegistry` records signed prices and refusals; and
- `ClaimResolver` reads the defined reserve conditions and settles valid claims.

## Covered conditions

Cover is tied to measurable Aave V3 reserve conditions:

- a reserve deficit above the defined floor;
- a sustained failure to redeem the supplied position; and
- a sustained stale or implausible reserve price.

Conditions are sampled across blocks and fixed in the position terms when cover
opens. The pool and the covered position are separate: the pool backs cover and
is not supplied into the reserve it covers.

## Live deployment

| Network | Chain | Venue | Asset |
|---|---:|---|---|
| X Layer mainnet | 196 | Aave V3 | USDT |
| X Layer testnet | 1952 | Local test venue | Test USDT |

The public landing page is in [`apps/web`](apps/web). Select **Open dashboard**
to connect a wallet and use the transaction controls.

## Run locally

From the workspace root:

```bash
pnpm install
pnpm --filter @xcover/pricing-agent build
set -a; source .env; set +a
HOST=127.0.0.1 PORT=8787 pnpm --filter @xcover/pricing-agent start
```

Open `http://127.0.0.1:8787/`.

## Calibration evidence

The benchmark corpus and its reports live in [`bench`](bench). The current
corpus contains 229 cited scenarios. Its results are preserved in the raw
artifacts; the present calibration work has not produced a measured operating
threshold yet.

The pricing service configuration and the exact calibration state are documented
in [`docs/pricing-agent.md`](docs/pricing-agent.md). Chain verification evidence
is in [`docs/chain-verification.md`](docs/chain-verification.md), and the
contract specification is in [`docs/SPEC.md`](docs/SPEC.md).

## Development checks

```bash
pnpm --filter @xcover/pricing-agent test
pnpm --filter @xcover/pricing-agent build
cd packages/contracts && forge test
```

The repository contains Solidity contracts, the pricing service, the web
dashboard, deployment records, chain verification, and reproducible benchmark
artifacts.
