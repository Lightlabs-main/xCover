# Deployments

Machine-readable records live in `deployments/*.json`, written by the deploy
scripts and committed. This file says what those records mean, and in particular
what each network does and does not prove.

Required reading order for the eligibility gate: **testnet first, then mainnet.**
The records carry chain id, block number, timestamp, deployment transaction
hashes and explorer links for every contract, so the order is verifiable on chain
rather than asserted here. `script/record_deployment.py` merges creation hashes
from Foundry's broadcast artifact after each real deployment.

---

## X Layer testnet — chain 1952

The corrected build was deployed **18 August 2026**, block 38581492,
timestamp 1787040329.
Record: [`deployments/xlayer-testnet.json`](../deployments/xlayer-testnet.json).

> The earlier deployment at block 38540175 is preserved in the history below and
> is not the current competition build. The current record is the corrected set.

| Contract | Address |
|---|---|
| `TestnetUSDT` (covered asset) | `0x13Ba8C8B4D50CCA1Ad268C5f9c74244F42C3A894` |
| `TestnetVenue` (venue) | `0x60F9C843298F0Ef99Df4CE3C611D310aa4Fdbe73` |
| `CoverPool` | `0x5Ef5F50391ecb540Eb6e44E260D6E9F102d752ff` |
| `CoverPolicy` | `0xF2426878788a41ce6119Fd42dcBc1c01a8b10243` |
| `PricingRegistry` | `0x06299277B523300AeD09581A7311C04346eC4F0a` |
| `ClaimResolver` | `0xdb3cf87E5C00C635D9c24003CbCbAE99fF69a3B3` |
| `xCoverVault` | `0x628402879de0e7E1Cd4f5B24EB0652FbFc1c2100` |

`termsHash` `0x3011f484e44ffe494015493b9f6ddbc04e526de0fc9f3b86ae99d65d9e47475f`.

Explorer links and creation transaction hashes for each are in the JSON record.

> The deployment at block 38540175 carried the earlier correctness batch but not
> the final ownership, cadence and testnet-floor changes. The original set at
> block 38522841 is also superseded and preserved at
> [`deployments/xlayer-testnet.superseded-38522841.json`](../deployments/xlayer-testnet.superseded-38522841.json).

**What backs it, stated plainly.** Full xCover contract set plus `TestnetVenue`, a
self-deployed custody-only venue, **because Aave V3 is not deployed on X Layer
testnet** — verified 17 August 2026, empty code at both `POOL` and
`POOL_ADDRESSES_PROVIDER` (`docs/chain-verification.md`). The covered asset is
`TestnetUSDT`, a real ERC-20 deployed by this project, because mainnet USDT has no
counterpart on 1952.

All xCover logic — policy lifecycle, solvency accounting, claim triggers, pricing
commitments, the refusal path — is the same code mainnet runs.

**What this deployment does not prove:** the Aave integration. `TestnetVenue` pays
no yield and does not pretend to; `hasYieldSource()` returns `false` and
`venueName()` returns `custody-only/xlayer-testnet`, so any UI reading the venue
states what is behind it. Premium on testnet is paid from the depositor's balance
rather than streamed from accrual. The Aave integration is proven separately by
the fork tests in `packages/contracts/test/fork/`, which run against the live
mainnet Pool, and by the mainnet deployment.

**Judge-triggerable claim.** `TestnetVenue.induceDeficit(address,uint256)` writes
off real assets from the venue, creating a shortfall that genuinely exists on
chain, so `ClaimResolver` samples a real condition and settles a real payout.
**This function does not exist on mainnet** — it is absent from `AaveV3Venue`
entirely rather than gated, and a fork test asserts the selector is absent from
its bytecode (mutation-checked: adding it makes the test fail).

**The honest cost of that, stated rather than buried.** `DEMO_ROLE` is held by the
deployer, so on testnet the admin *can* cause a claim to become payable — by
destroying real value in the venue, which is the only way it can be done. That is a
genuine weakening of the model-and-money separation, and it exists on testnet only,
because a judge cannot otherwise watch a payout without waiting for Aave to develop
a real deficit. On mainnet there is no such function and no such role: the deficit
the resolver reads is Aave's, and nothing xCover deploys can write it. The admin
there can pause new issuance and nothing else — it cannot deny a valid claim, block
a withdrawal, or cause a claim, and the separation tests assert each of those.


### The deficit trigger defect, and why it is recorded here

Found 17 August 2026, after the deployment above, while checking whether a real
Aave deficit could be caused by ordinary transactions. It can: a deficit is
recorded whenever a liquidation leaves an account with zero collateral and
non-zero debt, and it is cleared only by a permissioned Umbrella call with
[no time constraint](https://aave.com/docs/aave-v3/umbrella), so once nonzero it
stays nonzero.

The original trigger treated *any* nonzero deficit as a total loss and paid full
cover. Measured on Ethereum Aave V3 the same day:

| Reserve | Deficit | As a share of the reserve |
|---|---|---|
| USDT | 0.830980 on 2,971,945,009 supplied | 0.0000028 bp |
| DAI | 2,700 on 134,991,795 | 0.2 bp |
| cbBTC | 1 satoshi | ~0 |
| WETH | 52,964 on 2,177,894 | **243 bp** — a materially damaged reserve |

**27 of 67 reserves carried a nonzero deficit at the same moment.** A 10,000
policy would have paid in full against an implied depositor loss of one part in
3.6 billion. No attacker was required; this is the resting state of a mature
market. Every X Layer reserve reads zero today only because that market is young,
which made this a latent failure that would have looked correct until it fired.

The fix judges the deficit as a share of the reserve, the way the depeg is already
judged as a shortfall against peg: below `deficitFloorBps` there is no covered
event, and above it the payout is the depositor's pro-rata share of the hole. The
50 bp floor comes from the table above — eight orders of magnitude above the dust,
well below a real solvency event. Triggers also now settle on whichever held
condition implies the largest loss, so a small qualifying deficit cannot mask a
total redemption failure.

### Testnet parameters differ from mainnet, deliberately

This is the one place the two networks diverge in behaviour rather than in
dependencies, and it exists so the lifecycle can be watched in real time. Both
networks produce one block per second (measured over 500 blocks, 17 August 2026).

| Parameter | Testnet | Mainnet | Why |
|---|---|---|---|
| Waiting period | 300 blocks (5 min) | 86,400 blocks (24 h) | Adverse selection control. Testnet's is short enough to demonstrate live and still non-zero. |
| Sampling window | 120 blocks (2 min) | 1,800 blocks (30 min) | One manipulated block must not trigger a payout. Samples must span the full window. |
| Minimum samples | 5 | 30 | Mainnet samples ~once a minute, inside the 100 rps per-IP RPC limit. |
| Maximum observation gap | 30 blocks | 60 blocks | No unseen interval may exceed this bound. |
| Daily cover cap | 1,000,000 | 100,000 | Launch capital is small by design. |
| Depeg lower bound | $0.97 | $0.97 | Same on both. The live oracle read $0.99896524 under normal conditions — ~10 bp off peg — so the threshold clears observed noise by roughly 30x instead of firing on it. |
| Liquidity floor | 5,000 bp | 10,000 bp | Testnet keeps the induced 25% deficit visible; mainnet treats liquidity below 1x cover written as redemption failure. |
| Deficit floor | 50 bp | 50 bp | Same on both, and evidence-based — see the finding above. Below 0.5% of the reserve unbacked there is no covered event. Present in the deployed contracts as of the 17 August redeployment. |

`waitingPeriodBlocks`, `windowBlocks`, `minSamples`, `maxObservationGapBlocks` and `dailyCoverCap` are
**provisional**: `bench/threshold-derivation.md` now covers the deficit floor and the depeg
bound, but not these, so they remain reasoned defaults documented at their call sites in `script/Deploy*.s.sol`, not
derived ones. They must be revisited before the mainnet deployment.

### Superseded redeployment, 17 August 2026 — block 38540175

The original deployment carried the pre-fix deficit trigger, and correcting it
changed `Terms`, so `termsHash` moved from `0xace6897f…` to `0x1af6d4fd…`. A
policy's terms are fixed at mint and verified on that hash, so the deployed set
could not be upgraded into and was replaced. The superseded record is kept at
`deployments/xlayer-testnet.superseded-38522841.json` rather than discarded.

All seven contracts redeployed and the role wiring re-verified by reading the
chain, including a negative control confirming the pricer holds no admin role on
`CoverPool`. A fresh pricer key was generated for this deployment
(`0x48E94cd8f946cb10b79Ad27cEE38037c9b3eE909`); the previous pricer's key did not
survive to the machine that ran the redeployment.

### Corrected live lifecycle run on testnet

Driven against the corrected deployment at block 38581492. The run used the same
contract path a judge uses, with the deployer manually signing the quote because
the pricing agent is not written yet. The signed decision still went through
`PricingRegistry` and its `PRICER_ROLE` check.

| Stage | What ran | Result |
|---|---|---|
| `open()` | 100,000 tUSDT underwriting capital, a signed quote, and `depositCovered` of 10,000 tUSDT | Policy **#1** minted; 10,000 cover reserved; active from block 38581965 |
| `refuse()` | A signed `DECLINE_TO_QUOTE` recorded on the same path as a quote | `declinedCount` 1, `quotedCount` 1 |
| `observe()` | `induceDeficit` wrote off **2,500** tUSDT, then observations were submitted until five valid samples sat 20 blocks apart | Deficit 2,500 of 10,000 supplied = **2,500 bp**; venue holds 7,500 against 10,000 owed |
| `trigger` | `evaluate` against the terms hash fixed at mint | Trigger **1 = ReserveDeficit**, payout 2,500 tUSDT |
| `settle()` | `claim` paid the policy holder from `CoverPool` | **2,500 tUSDT paid.** Pool capital 100,000 → 97,500, outstanding cover → 0, policy #1 `Paid` |

The final valid observations were mined at blocks **38584964, 38584984,
38585004, 38585024 and 38585044**. The evaluation mined at block **38585064**;
all observation gaps were 20 blocks, the final sample was fresh, and the claim
receipt paid `2,500,000,000` base units. Direct reads afterwards confirmed
`triggerOf(1) = 1`, `claimAmount(1) = 2,500,000,000`, `coverOf(1) = 0`, pool
`capital() = 97,500,000,000`, venue `deficit() = 2,500,000,000`, venue balance
`= 7,500,000,000`, and policy state `Paid` (4).

The first attempts deliberately remain non-evidence: the public RPC delayed
transactions enough to create gaps larger than 30 blocks. The final run used
locally signed raw transactions through the official `/terigon` endpoint and
verified every receipt directly.

### Superseded live lifecycle run on testnet

Driven by `script/LifecycleTestnet.s.sol` against the deployed contracts. Staged,
because the waiting period and sampling window are real elapsed time. Figures
below are from the **redeployment** run.

| Stage | What ran | Result |
|---|---|---|
| `open()` | 100,000 tUSDT underwriting capital, a signed quote, and `depositCovered` of 10,000 tUSDT | Policy **#1** minted, 10,000 cover reserved, cover active from block 38540761 |
| `refuse()` | A signed `DECLINE_TO_QUOTE` recorded on the same path as a quote | `declinedCount` 1, `quotedCount` 1 |
| `observe()` | `induceDeficit` wrote off **2,500** tUSDT — a quarter of the position, not all of it — then 5 observations across the window | Deficit 2,500 of 10,000 supplied = **2,500 bp**; venue holds 7,500 against 10,000 owed |
| `trigger()` | `evaluate` against the terms hashed into the policy at mint | Trigger **2 = RedemptionFailure**, payout 10,000 — *not* the deficit trigger; see below |
| `settle()` | `claim` paid the policy holder from `CoverPool` | **10,000 tUSDT paid.** Pool capital 100,000 → 90,000, outstanding cover → 0, policy #1 `Paid` |

Cost of the redeployment and the full lifecycle: **0.000249 OKB**.

#### The deficit trigger was unreachable on this historical deployment

The partial write-off was meant to demonstrate the pro-rata payout: a 2,500 bp
deficit on 10,000 of cover should pay 2,500. It settled as a redemption failure
paying the full 10,000 instead, and the resolver was right to do so.

`TestnetVenue` custodies exactly one position, so its token balance equals the
cover written against it. Writing off any amount therefore drops redeemable
liquidity below the cover, which is the redemption-failure condition at
`liquidityFloorBps: 10000`. Because triggers settle on whichever held condition
implies the largest loss, the full-cover redemption failure outranks the deficit's
2,500 every time. **Any** deficit on this deployment produces that outcome, so the
deficit trigger cannot be observed on testnet at all.

This is an artefact of the venue holding a single position, not a contract defect,
and it does not affect mainnet: there the aToken holds the whole reserve — 50.2M
USDT against cover measured in tens of thousands — so redeemable liquidity sits
far above any policy's cover and only a genuine liquidity crisis trips that floor.

It means the historical testnet deployment demonstrated the redemption-failure
path rather than the deficit path. The current source now sets
`liquidityFloorBps: 5000` for testnet only, so the next broadcast can demonstrate
the 25% pro-rata deficit path. The pro-rata behaviour is already proven by unit
tests and live Aave fork tests, where 499 bp of the real reserve pays 2,495 USDT
on 50,000 of cover. The corrected lifecycle is recorded above.

Verified afterwards by reading the chain directly rather than trusting the script's
own log: policy state `4` (Paid), `triggerOf(1)` = 1, `coverOf(1)` = 0,
`capital()` = 90,000, venue balance 0 against 10,000 owed, registry showing one
quote and one refusal, nine observations recorded.

The whole thing — deployment, lifecycle, payout — cost **0.000252 OKB**.

The historical window also exposed the keeper constraint: observations were spaced
~28 blocks apart. The corrected resolver now requires samples to span the full
window, remain within the configured maximum gap, and have a fresh latest sample.
The next testnet lifecycle must keep observations within 30 blocks across the
120-block window; mainnet's 1,800-block window uses a 60-block maximum gap and
should target materially faster.

The quotes in this run were signed by hand with the pricer key, because the
pricing agent does not exist yet. That is not a shortcut around the trust model:
`PricingRegistry` verifies the signature and the `PRICER_ROLE` either way, so a
hand-signed decision goes through exactly the same door the agent will.

---

## X Layer mainnet — chain 196

**Not yet deployed.** `DeployMainnet.s.sol` is written and refuses to run unless
`deployments/xlayer-testnet.json` exists, so the required order cannot be skipped
by accident.

When it runs it deploys the identical xCover contract set plus `AaveV3Venue`,
bound to the live Aave V3 Pool and the real USDT reserve at the addresses in
`XLayerAddresses.sol`, verified in `docs/chain-verification.md`. **This is the
production system.**

Keys: the deployer holds `ADMIN_ROLE` (pause new issuance only — it cannot deny a
claim or block a withdrawal). A separate pricer key holds `PRICER_ROLE` and can
only produce prices and refusals. The deploy scripts refuse to run if the two are
the same key.
