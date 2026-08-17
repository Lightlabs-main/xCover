# Deployments

Machine-readable records live in `deployments/*.json`, written by the deploy
scripts and committed. This file says what those records mean, and in particular
what each network does and does not prove.

Required reading order for the eligibility gate: **testnet first, then mainnet.**
Both records carry chain id, block number, timestamp, and the deployment
transaction hash for every contract, so the order is verifiable on chain rather
than asserted here.

---

## X Layer testnet — chain 1952

Deployed **17 August 2026**, block 38522841, timestamp 1786981678.
Record: [`deployments/xlayer-testnet.json`](../deployments/xlayer-testnet.json).

| Contract | Address |
|---|---|
| `TestnetUSDT` (covered asset) | `0x5C63E71625C1ABC23A7f1A571e22fcdf1cc20345` |
| `TestnetVenue` (venue) | `0x9D169a232A70A0375297FAe02A2e325Ab4370764` |
| `CoverPool` | `0x8CaBB9bD14ad8E2b1d407Fa2f9Afe1a93922628E` |
| `CoverPolicy` | `0xb6A57100AedB262cb5aCfD748c72052489B78Ea5` |
| `PricingRegistry` | `0xecAC3585b8720E4Cb04CF54Af06022805a97f763` |
| `ClaimResolver` | `0x65BbFb3fA98ca6256f55e79Fd043250Da3FdC7C8` |
| `xCoverVault` | `0x530Cdd5aAd1BA7fE2A1eABcb4E813e587B1d0839` |

Explorer links for each are in the JSON record.

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

### Testnet parameters differ from mainnet, deliberately

This is the one place the two networks diverge in behaviour rather than in
dependencies, and it exists so the lifecycle can be watched in real time. Both
networks produce one block per second (measured over 500 blocks, 17 August 2026).

| Parameter | Testnet | Mainnet | Why |
|---|---|---|---|
| Waiting period | 300 blocks (5 min) | 86,400 blocks (24 h) | Adverse selection control. Testnet's is short enough to demonstrate live and still non-zero. |
| Sampling window | 120 blocks (2 min) | 1,800 blocks (30 min) | One manipulated block must not trigger a payout. |
| Minimum samples | 5 | 30 | Mainnet samples ~once a minute, inside the 100 rps per-IP RPC limit. |
| Daily cover cap | 1,000,000 | 100,000 | Launch capital is small by design. |
| Depeg lower bound | $0.97 | $0.97 | Same on both. The live oracle read $0.99896524 under normal conditions — ~10 bp off peg — so the threshold clears observed noise by roughly 30x instead of firing on it. |
| Liquidity floor | 10,000 bp | 10,000 bp | Redeemable liquidity below 1x cover written is a redemption failure. |

`waitingPeriodBlocks`, `windowBlocks`, `minSamples` and `dailyCoverCap` are
**provisional**: `bench/threshold-derivation.md` does not exist yet, so they are
reasoned defaults documented at their call sites in `script/Deploy*.s.sol`, not
derived ones. They must be revisited before the mainnet deployment.

### Live lifecycle run on testnet

Driven by `script/LifecycleTestnet.s.sol` against the deployed contracts. Staged,
because the waiting period and sampling window are real elapsed time.

| Stage | What ran | Result |
|---|---|---|
| `open()` | 100,000 tUSDT underwriting capital, a signed quote, and `depositCovered` of 10,000 tUSDT | Policy **#1** minted, 10,000 cover reserved, cover active from block 38523377 |
| `refuse()` | A signed `DECLINE_TO_QUOTE` recorded on the same path as a quote | `declinedCount` 1, `quotedCount` 1 |
| `observe()` | `induceDeficit` writes off 10,000 tUSDT, then observations recorded across the window | see run log |
| `trigger()` | `evaluate` against the terms hashed into the policy at mint | see run log |
| `settle()` | `claim` pays the policy holder from `CoverPool` | see run log |

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
