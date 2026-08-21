# xCover

**An autonomous AI pricing agent for fully backed Aave V3 USDT depositor cover
on X Layer.**

[Live application](https://xcover.online) ·
[Product documentation](https://xcover.online/docs) ·
[Mainnet deployment record](deployments/xlayer-mainnet.json) ·
[Contract specification](docs/SPEC.md)

xCover is built around an AI risk-pricing agent. It reads live Aave V3 and pool
state, retrieves cited risk evidence, runs two independent assessment passes,
and produces a signed price or signed refusal. Deterministic code computes and
bounds the premium, while the signed decision creates a public bridge from the
agent's reasoning to the contracts that enforce it.

That decision connects three things that are normally separate: a live risk
assessment, an Aave V3 deposit, and capital reserved to pay a valid claim. A
depositor records the agent's signed decision on X Layer and opens a covered
USDT position. In one transaction, xCover supplies the depositor's USDT to Aave
V3, mints a policy, and reserves matching USDT capacity in the underwriting pool.

The AI agent prices risk but never controls funds. Wallets authorize transfers;
contracts enforce quote validity, pool solvency, policy activation, observations,
and claim settlement.

> **Current status:** the contracts and X Layer mainnet integration are live.
> Pricing is explicitly provisional and unaudited while calibration continues.
> This is working protocol software, not a representation that the system has
> completed an independent security audit or offers regulated insurance.

## Why xCover exists

Aave depositors see an advertised yield, but they do not receive a live price
for the risks attached to that yield: reserve deficits, inability to redeem,
oracle failure, and smart-contract or integration failures. Existing cover
products are usually a separate purchase with separate terms, so users must
remember to buy protection after making the deposit.

xCover makes cover part of the position-opening flow:

1. Read the live Aave V3 reserve and underwriting pool.
2. Ask two independent model passes to assess cited risk evidence.
3. Compute a bounded premium deterministically.
4. Return a signed quote or signed refusal.
5. Record the decision publicly on X Layer.
6. Atomically open the Aave-backed position and reserve matching pool capital.

A refusal is a real result, not an application failure. Missing chain data,
unhealthy reserve state, insufficient pool capacity, expired pricing, or risk
outside configured bounds can stop issuance before user funds move.

## Who benefits

### A new Aave supplier

A user who plans to supply USDT to Aave can use xCover instead of supplying
directly. The user requests a quote, approves USDT, and opens the position through
`xCoverVault`. The vault supplies the USDT to the live Aave V3 venue and creates
the linked policy and vault shares in the same transaction.

### An existing Aave supplier

An existing Aave supplier already understands the value of the yield position
but may want explicit protection against the covered reserve conditions. In the
current build, that user can:

1. redeem the amount they want to protect from their direct Aave position back
   to USDT;
2. request a live xCover price for that USDT amount;
3. record the signed decision;
4. approve USDT to `xCoverVault`; and
5. reopen that amount as an Aave-backed covered position through xCover.

This gives the user one xCover position whose Aave supply, policy, owner, quote,
premium, and reserved backing are linked by contract state.

**Important current limitation:** xCover does not retroactively attach cover to
an arbitrary aUSDT balance that remains in an external wallet. There is no
`coverExistingATokenBalance` function in the deployed contracts. Requiring the
position to open through the vault prevents a policy from claiming to cover an
asset position that xCover cannot bind, size, or unwind. In-place wrapping of an
existing aUSDT position is a future product extension, not a feature claimed by
this deployment.

### An underwriter

An underwriter deposits USDT into `CoverPool` and receives pool shares. That
capital is separate from depositor assets and is not supplied to the Aave reserve
being covered. It remains available to pay valid claims and earns premium from
covered positions.

Underwriters can track:

- total pool capital;
- outstanding cover already reserved;
- free capital available for new policies;
- pool shares; and
- the maximum amount currently withdrawable.

Capital locked behind active cover cannot be withdrawn until the reservation is
released or settled.

## The complete user flow

### 1. Fund underwriting capacity

Capital providers approve USDT to `CoverPool`, deposit capital, and receive pool
shares. Direct token transfers are not counted as underwriting capital; the
deposit function measures the received amount and updates pool accounting.

### 2. Publish current reserve evidence

Anyone may call `ClaimResolver.recordObservation`. The caller chooses only when
to sample. The resolver reads the deficit, oracle price, redeemable liquidity,
and total supplied amount directly from the configured venue and Aave contracts;
the caller cannot submit invented values.

### 3. Request AI pricing

The pricing service reads live chain state and retrieves relevant entries from
the committed evidence corpus. Two independent assessment passes produce hazard,
uncertainty, confidence, concerns, and cited conclusions. Deterministic code then
computes the premium and applies hard gates for reserve state, pool capacity,
oracle conditions, model availability, confidence, disagreement, uncertainty,
and the configured premium ceiling.

The output is an EIP-712 signed decision containing the exact reserve, cover
amount, premium rate, expiry block, decision-document hash, engine version, and
nonce. The canonical decision document is publicly retrievable by hash.

### 4. Record the signed decision

Anyone may submit the signed decision to `PricingRegistry`; authority comes from
the recovered signer holding `PRICER_ROLE`, not from the transaction sender. The
registry records accepted quotes and refusals in the same public history.

An accepted quote:

- expires at a fixed block;
- is valid for one reserve and one exact amount;
- can be consumed only once; and
- must be consumed by `xCoverVault`.

### 5. Open the covered Aave position

`xCoverVault.depositCovered` performs the money-moving flow atomically:

1. transfer the buyer's USDT to the vault;
2. supply it through `AaveV3Venue` to the real Aave V3 Pool;
3. consume the recorded quote;
4. mint the policy with the quote and terms hashes attached;
5. reserve equal underwriting capacity in `CoverPool`; and
6. mint non-transferable vault shares to the position owner.

If any step fails, the whole transaction reverts. There is no uncovered deposit
path that could leave a user believing they have protection when they do not.

### 6. Activation, observations, and claims

Mainnet uses a block-based waiting period of 86,400 blocks, approximately 24
hours at the expected X Layer block cadence. The policy is minted immediately,
but a claim cannot be evaluated until activation. This reduces adverse selection
from users attempting to buy cover after an incident becomes visible.

After activation, the deployed mainnet terms require an approximately 30-minute
observation window, at least 30 samples, and bounded gaps between samples. Anyone
may publish observations, but the deterministic resolver decides whether the
recorded values satisfy the policy terms.

Covered conditions are deliberately narrow and measurable:

| Condition | On-chain evidence | Settlement principle |
|---|---|---|
| Reserve deficit | Aave reserve deficit as a share of total supplied assets | Pro-rata share of the measured shortfall above the configured floor |
| Redemption failure | Sustained lack of redeemable liquidity below the policy threshold | Triggers the deployed full-cover redemption-failure path |
| Oracle failure/depeg | Sustained implausible or below-bound reserve price | Pays the measured shortfall defined by the policy terms |

The AI does not approve claims. `ClaimResolver` evaluates fixed terms and calls
the policy and pool contracts to settle a valid result.

### 7. Exit

The position owner may exit the full position. The vault redeems from Aave,
settles accrued premium from the redeemed position assets, returns the remainder,
and cancels an untriggered policy so its pool reservation is released. If a
policy has already become claimable or paid, exit does not destroy the claim.

Partial exits and share transfers are intentionally disabled in this build
because the vault position and policy are owner-linked and must not diverge.

## Core features

| Feature | What the build enforces |
|---|---|
| Live Aave V3 integration | Mainnet depositor USDT is supplied to the configured X Layer Aave V3 Pool; reserve state is read from live contracts. |
| AI pricing | Two model passes assess cited evidence; deterministic code computes and bounds the premium. |
| Signed, replayable decisions | EIP-712 decisions and canonical JSON hashes make quotes and refusals attributable and auditable. |
| Fully backed underwriting | `capital >= outstandingCover`; issuance and withdrawals cannot break the invariant. |
| Atomic covered deposits | Aave supply, quote consumption, policy mint, capital reservation, and share mint all succeed or revert together. |
| Quote expiry and one-time use | A quote is amount-bound, reserve-bound, block-limited, and consumable once. |
| Daily capacity limits | New cover written per reserve is capped each day in addition to pool solvency limits. |
| Waiting-period protection | Mainnet cover activates only after 86,400 blocks. |
| Permissionless observations | Any wallet can record a sample, while contracts determine the sampled values. |
| Deterministic claims | Fixed policy terms and sampled on-chain evidence determine triggers and payout amounts. |
| Safe early exit | Exiting during the waiting period cancels the active policy and releases reserved capital. |
| Correct event linkage | `QuoteConsumed` emits the actual upcoming policy ID rather than policy ID zero. |
| Separation of authority | The pricer cannot move funds or settle claims; the admin can pause new issuance but cannot block exits or valid settlement. |

## Contract architecture

| Component | Responsibility |
|---|---|
| `CoverPool` | Holds underwriting USDT, issues provider shares, reserves cover, receives premium, and pays claims. |
| `CoverPolicy` | Mints non-transferable ERC-721 policy positions and enforces waiting period, daily cap, and lifecycle state. |
| `PricingRegistry` | Verifies and records signed prices and refusals; consumes accepted quotes once. |
| `xCoverVault` | Supplies depositor USDT to Aave, creates the linked policy, tracks shares, accrues premium, and exits positions. |
| `AaveV3Venue` | Isolates the real Aave V3 supply/withdrawal and reserve-reading integration. |
| `ClaimResolver` | Records permissionless observations and deterministically evaluates and settles covered events. |
| Pricing agent | Reads chain state and cited evidence, performs two assessments, computes a bounded rate, and signs the decision. |
| Web dashboard | Displays live state and guides wallets through underwriting, quoting, recording, covered deposit, observation, and exit. |

## Live X Layer deployment

The current mainnet contract set was deployed on X Layer chain 196 at block
`68537850`. The application loads these addresses from the same machine-readable
manifest used by the pricing service.

| Component | Address |
|---|---|
| USDT | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |
| Aave USDT aToken | `0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297` |
| `AaveV3Venue` | `0x23a2Ae137030034e604fEE085169bfaFad6Fc1a9` |
| `CoverPool` | `0xe47298EA2ce467555044Dd707A646F9dF863bb87` |
| `CoverPolicy` | `0xD4A4Dd34e76e42ec206f65D0fC9F7eCb09A895fa` |
| `PricingRegistry` | `0x35072d8AB440B3b52942A04B5a67179e46eF6692` |
| `ClaimResolver` | `0xa18Ae50fc36194833155084bE21962EC3695aF3D` |
| `xCoverVault` | `0x51025304e7aaaB594F55e8d92DF334257A65E2Be` |

See [`deployments/xlayer-mainnet.json`](deployments/xlayer-mainnet.json) for
deployment transaction hashes and [`docs/deployments.md`](docs/deployments.md)
for the deployment history, testnet lifecycle, and corrected contract set.

## Safety model and current limitations

- The live deployment and pricing service are provisional and unaudited.
- xCover is cover software, not a representation of regulated insurance.
- Existing external aUSDT positions cannot currently be wrapped in place.
- Vault shares and policy NFTs are non-transferable in this build.
- Positions support full exit only; partial withdrawal is disabled.
- Mainnet claims cannot be fabricated for a demonstration. They require the real
  waiting period, observations, and a covered Aave condition.
- Pricing calibration remains in progress; the live engine reports that status.
- Contract invariants and tests reduce known implementation risk but are not a
  substitute for an independent audit.

## Verification and tests

The repository includes:

- unit tests for every contract component;
- invariant tests for pool solvency and policy reservations;
- fork tests against the real X Layer Aave V3 deployment;
- agent tests for signatures, evidence validation, pricing gates, and replay;
- deployment scripts with mainnet redeployment protection;
- machine-readable deployment records and broadcast artifacts; and
- chain-integration verification notes.

Run the full suite:

```bash
pnpm install
PATH="$HOME/.foundry/bin:$PATH" pnpm test
```

The current suite contains 140 Solidity tests plus the pricing-agent tests. Fork
tests require an accessible X Layer mainnet RPC.

## Repository map

```text
apps/web/                 Live dashboard and public product documentation
packages/agent/           Pricing service, evidence retrieval, decision signing
packages/contracts/       Solidity contracts, scripts, unit/fork/invariant tests
deployments/              Current and superseded machine-readable deployments
docs/                     Specification, pricing, chain verification, deployment notes
bench/                    Evidence corpus, benchmark tools, and calibration artifacts
```

## Run locally

```bash
pnpm install
pnpm --filter @xcover/pricing-agent build
set -a
source .env
set +a
HOST=127.0.0.1 PORT=8787 pnpm --filter @xcover/pricing-agent start
```

Open `http://127.0.0.1:8787/`.

## Further reading

- [Product and contract specification](docs/SPEC.md)
- [Pricing-agent design and status](docs/pricing-agent.md)
- [Deployment records and lifecycle evidence](docs/deployments.md)
- [Live-chain integration verification](docs/chain-verification.md)
- [Public web application notes](apps/web/README.md)
