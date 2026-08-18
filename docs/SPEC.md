# xCover — Engineering Specification

**Depositor cover for Aave V3 on X Layer, priced by an autonomous agent, bundled at deposit.**

**Target:** X Layer AI Season — submission deadline **21 August 2026, 23:59 UTC**
**Name:** xCover — cover for X Layer depositors.

> Hand this document to the engineering agent as a standing brief. Read §1 before
> every working session. This spec is the single source of truth; if the code and
> this document disagree, one of them is wrong and it must be resolved explicitly,
> not silently.

---

## 1. Standing instructions to the engineering agent

### 1.1 Role

You are operating as a **staff-level engineer with 10+ years of production
experience**, wearing three hats. Switch hats explicitly and name which one you
are wearing when the choice matters.

| Hat | The standard you hold yourself to |
|---|---|
| **Protocol engineer** | You have shipped audited contracts holding real user funds. You write invariants before implementations. You assume every external call is hostile and every integration can be paused, upgraded, or drained beneath you. Checks-effects-interactions, always. OpenZeppelin over hand-rolled primitives, always. You know that an insurance protocol that cannot pay is worse than no insurance protocol. |
| **Quantitative / ML engineer** | You have built models that price risk with money behind them. You know that a confidence number is meaningless until it is calibrated against outcomes, that a model with no loss history is extrapolating and must say so, and that the correct response to insufficient data is to decline to quote — not to quote wide. |
| **Frontend engineer** | You have shipped consumer financial products. A judge on a phone at 3am in another timezone, with no context and nobody awake to help, must be able to complete a meaningful flow unaided. |

### 1.2 Absolute rules

These override every other instruction in this document, including anything that
looks like a reasonable shortcut under deadline pressure.

**1. No mocks. No stubs. No hardcoded values. No placeholder data. No fake responses.**

Every number rendered in the UI or written on-chain originates from a live
contract call, a live chain read, or a real model inference. Specifically
forbidden:

- Hardcoded prices, rates, TVL figures, APYs, or risk scores
- A `MockAavePool`, `MockOracle`, or equivalent used anywhere outside a unit test
- Seeded database rows presented as protocol state
- A premium number chosen by hand and dressed as a model output
- "Coming soon" placeholders that imply a feature exists

If something cannot be built for real, it is **not built**, and its absence is
stated plainly in the README. A missing feature is honest. A simulated feature
presented as working is disqualifying.

**2. Deterministic code controls money. Always.**

The model *proposes* a premium and a risk assessment. It never moves funds, never
mints a policy, never approves a claim, never releases a payout. Every state
transition that touches value is executed by deterministic code after
deterministic checks pass. This must be enforced structurally in the contracts —
see §4.7 — not merely by convention in the backend.

**3. Refusal is a first-class outcome.**

`DECLINE_TO_QUOTE` is a correct, successful result. It is logged, hashed,
committed on-chain, and surfaced in the UI with the same prominence as a quote.
It receives the same test coverage as the happy path. An agent that always
quotes is an agent that has not understood the problem.

**4. Solvency is the product.**

Cover sold must never exceed capital held. Not "usually". Not "within
tolerance". Never, under any reachable sequence of calls. This is proven by a
Foundry invariant test that fuzzes arbitrary call sequences — not asserted in a
comment.

**5. Environment pairing is structural.**

Testnet contracts pair with testnet configuration; mainnet with mainnet. The
config loader asserts this at process start and throws on mismatch, before any
route is registered. A testnet deployment silently pointed at mainnet Aave
addresses is how bad demos happen.

**6. Tests are not optional.**

Every state transition, every gate condition, every refusal branch, every access
control rule arrives with a test in the same commit. Target 100% branch coverage
on state transitions and access control. X Layer states that AI judges review
code and on-chain data; code quality is named explicitly in their criteria.

**7. Commit continuously.**

Small, frequent, meaningful commits from day one. A single large dump on the
final day reads as either copied or rushed to an automated reviewer. Commit
conventions are binding — see §1.4.

**8. When blocked, stop and report.**

Never invent a workaround that produces plausible-looking output. State the
blocker plainly, state what you tried, and propose options. A blocked task
reported honestly costs an hour; a fabricated workaround costs the submission.

### 1.3 Working agreement

- Maintain `PROGRESS.md`: what is done, what is next, what is blocked. Update it
  at the end of every session.
- Propose the interface before implementing it. Get agreement on shape first.
- After every significant change, run the full test suite and report the result
  honestly, including failures.
- Nothing is marked "done" until it has been executed end to end at least once
  against a real dependency on a real chain.

### 1.4 Commit conventions — binding

- **Author.** Every commit is authored as **lightlabs**. The exact email is
  supplied by the project owner; ask before the first commit and set
  `user.name` / `user.email` on the repository. No other identity appears in the
  history.
- **No AI attribution.** No `Co-Authored-By` trailer, no "Generated with"
  footer, no tool or model name anywhere in a commit message, ever.
- **Clean messages.** A short imperative subject describing the change itself.
  No `phase 3`, no `gate`, no day numbers, no schedule references, no emoji, no
  ticket-style prefixes.

  ```
  good:  add solvency invariant test for CoverPool
         record X Layer chain verification output
         enforce quote freshness at policy mint

  bad:   Phase 2: CoverPool ✅
         day 3 gate passed
         wip
  ```

---

## 2. The product

### 2.1 One sentence

> xCover lets a depositor on X Layer supply to Aave and receive protection for
> that position in the same transaction, priced continuously by an agent that
> declines to quote when it cannot price the risk honestly.

### 2.2 The problem

Every depositor in an Aave reserve carries risk they did not choose and cannot
price: smart-contract failure, oracle failure, wrapper or bridge failure on the
xBTC / xETH / xSOL / xBETH / xOKSOL reserves, and liquidity conditions that
prevent withdrawal. They receive a yield number. They receive no risk number.

Cover exists elsewhere — Nexus Mutual, InsurAce, others — and covers roughly a
low single-digit percentage of DeFi TVL. Two structural reasons, both fixable:

**Cover is sold separately from the deposit.** It is a second decision, a second
transaction, a second fee, taken at the moment the user is least worried. Almost
nobody makes it. The correct fix is to make cover a property of the position
rather than a product bought alongside it.

**Cover is priced by hand.** On existing mutuals, underwriters create pools and
set prices manually in governance forums. Prices go stale, do not respond to
utilisation or market conditions, and are not calibrated against outcomes.

xCover addresses both: cover is minted with the deposit and paid for out of the
yield that deposit already earns, and the price is set per-block by an agent
reading live protocol state.

### 2.3 What is covered — three definable events

Every covered event must be measurable by a contract call. If a human has to
form a judgement, it is not covered, and the terms say so explicitly.

| Event | Trigger | Measurement |
|---|---|---|
| **Reserve deficit** | Aave records bad debt in the covered reserve | `POOL.getReserveDeficit(asset) > 0` — see §3.2 |
| **Redemption failure** | aToken fails to redeem within tolerance of 1:1 over a sustained window | Sampled on-chain over N blocks; tolerance and window fixed in policy terms at mint |
| **Oracle failure** | Price source for the reserve reports stale or implausible data over a sustained window | `AaveOracle` reads sampled over N blocks against defined staleness and deviation bounds |

Everything else is explicitly out of scope, listed in the terms, and shown in the
UI at purchase. Narrow and automatic beats broad and discretionary. Payouts
settle in blocks, not weeks.

### 2.4 What this is not

- **Not insurance.** Use "cover", "protection", "discretionary mutual". This is
  the established convention in the category and it is a deliberate legal
  distinction, not a stylistic one.
- **Not protocol-level coverage.** xCover pays the individual depositor for
  their own loss. It does not repair Aave's balance sheet, does not reduce a
  reserve deficit, and makes no claim to. Aave's own deficit-elimination
  machinery is permissioned to governance-registered entities; xCover neither
  duplicates it nor depends on it.
- **Not a yield product.** Capital providers earn premium income for bearing
  risk. That is underwriting, not farming, and the distinction must be clear in
  the UI so nobody deposits capital expecting a yield vault.

---

## 3. Verified integration facts

Verified against the Aave DAO address book (`aave-dao/aave-address-book`,
`src/AaveV3XLayer.sol`) and X Layer ecosystem sources. **Re-verify every address
on chain before wiring it.** See §3.3.

### 3.1 Aave V3 on X Layer — core

| Contract | Address |
|---|---|
| `POOL` | `0xE3F3Caefdd7180F884c01E57f65Df979Af84f116` |
| `POOL_ADDRESSES_PROVIDER` | `0xdFf435BCcf782f11187D3a4454d96702eD78e092` |
| `POOL_CONFIGURATOR` | `0x1408b48B6A610948f04813EA6b2F438A6BBAd2f2` |
| `ORACLE` (AaveOracle) | `0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6` |
| `AAVE_PROTOCOL_DATA_PROVIDER` | `0x6C505C31714f14e8af2A03633EB2Cdfb4959138F` |
| `POOL_IMPL` | `0x5Bc7204274230a8F4778a35A58B776D16CF104b4` |
| `UI_POOL_DATA_PROVIDER` | `0xc851e6147dcE6A469CC33BE3121b6B2D4CaD2763` |
| `RISK_STEWARD` | `0x7D0219C7037819B3F5d73E235C595189C3F8c224` |

### 3.2 Reserves

Nine live reserves: **USDT, USDG, GHO, xBTC, xETH, xSOL, WOKB, xBETH, xOKSOL.**

Launch covering **USDT only.**

| | Address |
|---|---|
| `USDT_UNDERLYING` | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` (6 decimals) |
| `USDT_A_TOKEN` | `0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297` |
| `USDT_V_TOKEN` | `0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac` |
| `USDT_PRICE_FEED` (Chainlink-style feed; not `IAaveOracle`) | `0x7ec7E5497EAf312FE82F8307D05eb0E5f0f157D3` |

Rationale for USDT-only at launch: it is the deepest stable reserve, the payout
asset and the covered asset are the same denomination (no FX exposure in the
claim), and a single reserve keeps the correlation surface small enough to
reason about honestly.

The wrapped reserves (xBTC, xETH, xSOL, xBETH, xOKSOL) carry an additional
wrapper/bridge failure mode on top of protocol risk. That is a real second
product and a good expansion story — do not build it now, and say why in the
README.

### 3.3 Day-one on-chain verification — blocking

The `getReserveDeficit` function on `Pool` was introduced in Aave v3.3. The X
Layer deployment shows post-3.2 markers (`DUST_BIN`, `STATA_FACTORY`, liquid
eModes), so it is very likely present, but **this has not been confirmed by a
chain call and it is the single blocking dependency for the primary claim
trigger.**

Before writing any pricing or claims code, run and record:

```bash
# 1. Does getReserveDeficit exist and return cleanly?
cast call 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 \
  "getReserveDeficit(address)(uint256)" \
  0x779Ded0c9e1022225f8E0630b35a9b54bE713736 \
  --rpc-url $XLAYER_RPC

# 2. Confirm the Pool implementation behind the proxy
cast call 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 \
  "POOL_REVISION()(uint256)" --rpc-url $XLAYER_RPC

# 3. Reserve state — confirms the reserve is live and active
cast call 0x6C505C31714f14e8af2A03633EB2Cdfb4959138F \
  "getReserveData(address)" \
  0x779Ded0c9e1022225f8E0630b35a9b54bE713736 \
  --rpc-url $XLAYER_RPC

# 4. aToken totalSupply — confirms real deposits exist
cast call 0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297 \
  "totalSupply()(uint256)" --rpc-url $XLAYER_RPC

# 5. Oracle liveness
cast call 0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6 \
  "getAssetPrice(address)(uint256)" \
  0x779Ded0c9e1022225f8E0630b35a9b54bE713736 \
  --rpc-url $XLAYER_RPC
```

Record every raw response in `docs/chain-verification.md` with the block number
and timestamp. Commit it. This file is evidence, and reviewers notice it.

**If `getReserveDeficit` reverts or does not exist:** fall back to redemption
failure as the primary trigger (§2.3, row 2), state the substitution plainly in
the README, and do not pretend the deficit trigger is live. Do not proceed on an
assumption.

### 3.5 Testnet deployment strategy — read before day 2

X Layer's rules are explicit and are an eligibility gate, not a preference: the
project must be deployed on X Layer **testnet during** the hackathon and
**subsequently launched** on X Layer **mainnet**. Both deployments must exist and
the order must be provable.

**The complication:** Aave V3 is deployed on X Layer **mainnet**. It is almost
certainly **not** deployed on X Layer testnet — the address book has no testnet
entry. So a testnet deployment of xCover cannot have a live Aave integration
behind it.

**Verify first, day one:**

```bash
# Does an Aave Pool exist at any known address on X Layer testnet?
cast code 0xE3F3Caefdd7180F884c01E57f65Df979Af84f116 --rpc-url $XLAYER_TESTNET_RPC
# Empty output (0x) = not deployed. Record the result either way.
```

**If Aave is absent from testnet — the expected case — deploy in this shape:**

xCover's contracts are split so that the Aave dependency lives behind one
interface:

```
CoverPool          no Aave dependency  → deploys to testnet unchanged
CoverPolicy        no Aave dependency  → deploys to testnet unchanged
PricingRegistry    no Aave dependency  → deploys to testnet unchanged
ClaimResolver      reads Aave via IYieldVenue → interface-bound
xCoverVault        supplies via IYieldVenue    → interface-bound
```

Introduce `IYieldVenue` with two implementations. **As built** (this replaces an
earlier sketch in this section that named `supply`/`deficit`/`oracleHealth` as
separate calls; the built interface is the binding one):

```solidity
interface IYieldVenue {
    function asset() external view returns (IERC20);
    function venueName() external view returns (string memory);
    function hasYieldSource() external view returns (bool);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets) external returns (uint256 supplied);
    function withdraw(uint256 assets, address to) external returns (uint256 redeemed);

    // The three readings ClaimResolver samples, taken live at the current block.
    function observeReserve(address reserve, address aToken)
        external view returns (uint256 deficit, uint256 price, uint256 redeemableLiquidity);
}
```

The three trigger readings are grouped into one `observeReserve` call rather than
three separate ones because the resolver samples them together, as one block's
worth of state. Splitting them would let a caller record a deficit from one block
and a price from another and call the pair an observation.

- `AaveV3Venue` — mainnet. Wraps the real addresses in §3.1.
- `TestnetUSDT` — testnet only. The covered asset. `XLayerAddresses.USDT` is a
  mainnet address with no counterpart on 1952, so without this the testnet
  deployment could not accept a deposit at all. A real ERC-20 with real balances,
  mirroring mainnet USDT's 6 decimals so that amounts, the oracle's 8-decimal peg
  comparison, and the pricing terms are the same numbers on both networks. `mint`
  is deliberately open: a judge needs tokens without asking anyone, and the token
  is worthless by construction. Not deployed to mainnet.
- `TestnetVenue` — testnet only. A minimal, **fully functional** lending venue
  xCover deploys itself: real supply, real withdraw, real interest accrual, real
  deficit accounting. It is not a mock of Aave's behaviour returning canned
  values; it is a working venue with the same interface, whose state a judge can
  inspect on the testnet explorer.

**This is not a violation of rule 1.2.1.** A mock returns fabricated data to make
a demo look complete. `TestnetVenue` is a real deployed contract with real state,
used on a testnet where the production dependency does not exist. The distinction
must be documented, not glossed:

> `docs/deployments.md`, stated plainly:
> **Testnet:** full xCover contract set + `TestnetVenue`, a self-deployed lending
> venue, because Aave V3 is not deployed on X Layer testnet. All xCover logic —
> policy lifecycle, solvency invariant, claim triggers, pricing commitments — is
> identical to mainnet.
> **Mainnet:** identical xCover contract set + `AaveV3Venue`, integrated with the
> live Aave V3 deployment. This is the production system.

**What testnet is for, concretely:**

1. Satisfying the eligibility requirement, with provable timestamps.
2. Exercising the full policy lifecycle end to end — mint, accrue, trigger,
   claim, expire, cancel — without spending mainnet gas or risking real capital.
3. Letting a judge trigger a claim themselves. On testnet, `TestnetVenue` exposes
   a permissioned `induceDeficit()` so a judge can watch `ClaimResolver` fire and
   a payout settle, live, in their own browser. **On mainnet this function does
   not exist** — it is not gated, it is absent from `AaveV3Venue` entirely, and
   there is a test asserting the mainnet venue exposes no such surface.

That third point is worth more than it looks. It gives a judge a hands-on payout
demonstration in addition to the fork test, on a real deployed chain, with no
install and nobody awake.

**Deployment order and evidence:**

```
Day 2  → X Layer testnet   (xCover contracts + TestnetVenue)
Day 5  → X Layer mainnet   (xCover contracts + AaveV3Venue)
```

Record both sets in `deployments/xlayer-testnet.json` and
`deployments/xlayer-mainnet.json`, committed, each with contract addresses,
deployment transaction hashes, block numbers, and timestamps. Link both in the
README with explorer URLs so the required sequence is visible without anyone
having to take your word for it.

**Environment pairing (rule 1.2.5) applies here:** the config loader asserts that
a testnet chain ID resolves to `TestnetVenue` and a mainnet chain ID resolves to
`AaveV3Venue`, and throws at process start otherwise. A mainnet deployment must
never be able to load a venue with an `induceDeficit` function.

### 3.6 Codify the verification

Write `script/VerifyIntegration.s.sol` — a Foundry script asserting every address
above responds as expected — and wire it as `pnpm verify:chain`. Run it in CI and
before every deployment. An address book entry can go stale; a failing assertion
catches it before users do.

---

## 4. Contracts

Five contracts. Keep them small enough to reason about completely.

```
CoverPool          capital, solvency accounting, premium distribution
CoverPolicy        ERC-721 policy positions, lifecycle state
xCoverVault        ERC-4626 wrapper: deposit → Aave + policy, atomically
ClaimResolver      deterministic trigger evaluation and payout
PricingRegistry    agent-signed quotes, on-chain record of every decision
```

### 4.1 CoverPool

Holds underwriting capital in USDT. Accounts for outstanding cover. Distributes
premium to capital providers. Pays claims.

```solidity
uint256 public capital;              // total USDT held
uint256 public outstandingCover;     // sum of active policy payout obligations
uint256 public constant RESERVE_RATIO_BPS = 10_000; // 100% — full collateral
```

**The core invariant:**

```
capital >= outstandingCover
```

Full collateralization. Not fractional. Traditional insurers hold fractional
reserves because they rely on the law of large numbers across uncorrelated
risks; your risks are perfectly correlated (one exploit hits every policy at
once) and your book is tiny. Full backing is the only honest choice, and it
means the pool **cannot** become insolvent.

Say this plainly in the pitch: *this protocol cannot fail to pay, by
construction.*

Any `mintPolicy` call that would breach the invariant **reverts**. Not queued,
not partially filled — reverts, with a clear custom error.

**Capital provider accounting:** ERC-4626-style shares. Providers can withdraw
only down to the point where the invariant still holds; capital backing active
cover is locked until those policies expire. This is not a UX wart, it is the
mechanism, and the UI must show locked vs free capital explicitly.

### 4.2 CoverPolicy (ERC-721)

```
Quoted ──mint──────► Active
Active ──expiry────► Expired
Active ──trigger───► Claimable
Claimable ──claim──► Paid
Active ──cancel────► Cancelled   (pro-rata premium refund)
```

Policy data:

```solidity
struct Policy {
    address reserve;          // covered asset (USDT at launch)
    uint256 coverAmount;      // payout ceiling, in reserve decimals
    uint64  startBlock;       // waiting period measured from here
    uint64  endBlock;
    uint256 premiumRateRay;   // per-block rate, from the signed quote
    bytes32 quoteHash;        // links to PricingRegistry record
    bytes32 termsHash;        // hash of the covered-events terms at mint
    PolicyState state;
}
```

**Waiting period.** Cover does not activate until `startBlock + WAITING_PERIOD`.
Without this, anyone who spots trouble buys cover before the payout. Standard
insurance practice; a few lines of code; name it in the README as an adverse
selection control.

**Per-venue daily cap.** New cover written per reserve per day is capped. Same
reason. Same treatment.

**Position ownership.** Policy NFTs and vault shares are non-transferable in this
build. `xCoverVault.positions` is keyed by address, so allowing either token to
move independently would strand exit rights or let the old address cancel the
new holder's position. Transferability requires a single atomic transfer path
for both records and is deliberately deferred.

**Premium accrues per block** and streams from the position's yield. There is no
recurring payment for the user to forget.

### 4.3 xCoverVault (ERC-4626)

The mechanism that fixes the "nobody buys cover" problem.

```
deposit(assets) →
    1. pull USDT from user
    2. supply to Aave POOL, receive aUSDT
    3. request quote from PricingRegistry (must be fresh and signed)
    4. mint CoverPolicy sized to the deposit
    5. mint vault shares to user
```

One transaction. The user makes one decision — deposit — and receives a covered
position. Premium streams out of accrued yield.

**Withdrawal** unwinds symmetrically: burn shares, close policy pro-rata, redeem
from Aave, return USDT.

**If no valid quote is available** — because the agent declined, or the pool
lacks capacity — the vault reverts with a clear error and the user is told why.
It does **not** silently deposit without cover. That would be the worst possible
failure: a user believing they are protected when they are not.

**Conflict of interest, and how it is handled.** `CoverPool` capital must **not**
be supplied to the same Aave reserve the pool covers. If it were, the collateral
would lose value at precisely the moment claims trigger — the reflexivity failure
that broke first-generation cover protocols. Enforce it in code: `CoverPool` has
no approval to the Aave Pool for any covered reserve, and there is a test
asserting it.

### 4.4 ClaimResolver

Deterministic. No model, no governance, no multisig discretion.

```solidity
function evaluate(uint256 policyId) external returns (ClaimStatus);
```

For each covered event, sample the on-chain condition over the defined window,
compare against the thresholds fixed in the policy's `termsHash`, and return a
status. If triggered, the payout is computed and the policy becomes `Claimable`;
anyone may then call `claim` on behalf of the holder.

**Sampling matters.** A single-block read is manipulable via flash loan. Sample
over N blocks, require the observations to span the full window, require the
newest observation to be fresh, and reject any gap larger than the
`maxObservationGapBlocks` fixed in the terms. The guarantee is bounded-cadence
sampled evidence, not an unobserved claim that every block was inspected.

**No admin override.** There is no function letting anyone deny a valid claim or
approve an invalid one. Write a test asserting no privileged role can alter
claim outcomes.

### 4.5 PricingRegistry

Stores agent-signed quotes and — critically — a hash of **every** pricing
decision, including refusals.

```solidity
struct QuoteRecord {
    bytes32 decisionHash;    // hash of canonical decision JSON
    address reserve;
    uint256 premiumRateRay;  // zero when declined
    uint64  validUntilBlock;
    bool    declined;
    string  engineVersion;   // e.g. "pricing-1.2.0/xlayer-usdt"
}
```

The full decision — inputs read from chain, computed risk factors, model
reasoning, confidence, the threshold applied, verdict — is served publicly at
`GET /decision/:hash`. Anyone can fetch it, canonicalise it (RFC 8785 / JCS),
hash it, and confirm it matches the on-chain commitment.

**Quotes expire.** A stale quote is a mispriced policy. `validUntilBlock` is
short and enforced at mint.

### 4.6 Access control

OpenZeppelin `AccessControl`, explicit roles:

- `PRICER_ROLE` — submit signed quotes to `PricingRegistry`. Nothing else.
- `KEEPER_ROLE` — trigger `evaluate` and settlement. Cannot alter outcomes.
- `ADMIN_ROLE` — pause new policy issuance only.

### 4.7 Structural separation of model and money — required tests

Three tests that must exist and must be named clearly enough that a reviewer
finds them:

```
test_PricerCannotMovePoolFunds()
test_PricerCannotAlterClaimOutcome()
test_AdminCannotDenyValidClaim()
```

These are the equivalent of a "compliance role cannot touch escrow" property.
They are the most persuasive tests in the suite because they prove rule 1.2.2
holds at the contract level rather than by convention. Reference them explicitly
in the README.

**Pausing must never block claims or withdrawals.** `ADMIN_ROLE` pauses new
issuance only. A user's ability to claim or exit does not depend on anyone's
cooperation. Test it.

---

## 5. The pricing agent

### 5.1 What it is actually doing

Given a reserve and a cover amount, produce a per-block premium rate — or
decline. The output is a price with money behind it, so every step must be
defensible.

### 5.2 Pipeline

```
1. READ        (deterministic, no model)
               Live chain state for the reserve:
                 - total supply, total borrows, utilisation
                 - current deficit (getReserveDeficit)
                 - reserve configuration and caps
                 - oracle price, staleness, deviation from peg
                 - aToken/underlying redemption ratio
                 - available liquidity vs outstanding cover

2. RETRIEVE    (deterministic, no model)
               Protocol-level evidence corpus:
                 - Aave V3 incident history across ALL deployments
                 - audit reports and dates
                 - time since this deployment launched
                 - governance actions affecting this reserve
               Grounding corpus. The model sees only retrieved evidence.

3. ASSESS      (model)
               Evaluates retrieved evidence, produces a structured risk
               assessment: hazard factors, confidence, concerns, missing facts,
               and a citation for each conclusion. Cannot claim what it cannot
               cite.
               Run twice with different framings. Disagreement between passes is
               a measured signal — it reduces confidence. It is not noise.

4. COMPUTE     (deterministic, no model)
               premium = baseHazard
                       × utilisationMultiplier
                       × concentrationMultiplier
                       × (1 + uncertaintyLoading)
                       × (1 + capitalCostMargin)
               The model's assessment feeds baseHazard and uncertaintyLoading.
               It does not produce the final number directly.

5. GATE        (deterministic, no model)
               confidence < threshold            → DECLINE_TO_QUOTE
               missing material facts            → DECLINE_TO_QUOTE
               ensemble disagreement             → DECLINE_TO_QUOTE
               reserve deficit already non-zero  → DECLINE (event in progress)
               oracle stale beyond bound         → DECLINE
               pool capacity insufficient        → DECLINE (capacity, not risk)
               otherwise                         → QUOTE

6. SIGN & POST (deterministic)
               Sign the quote, post to PricingRegistry with the decision hash.
```

### 5.2.1 Parameter provenance

The pipeline above defines behavior, but it does not define a value for every
runtime control. Do not silently turn an implementation default into a product
claim. The current provenance is:

| Control | Status | Source of truth |
|---|---|---|
| `deficitFloorBps = 50` | **Defined** | Contract terms and `bench/threshold-derivation.md` |
| `depegLowerBound = 97_000_000` (8 decimals) | **Defined** | Contract terms and `bench/threshold-derivation.md` |
| Confidence gate threshold | **Must be derived** | §5.4 calibration curve; not an intuition/default |
| Ensemble disagreement bound | **Must be derived/reviewed** | Benchmark disagreement measurements |
| Uncertainty-loading bound | **Must be derived/reviewed** | Cross-deployment extrapolation and benchmark evidence |
| Capital-cost margin | **Must be reviewed** | Underwriting economics; no numeric value is specified here |
| Oracle freshness and source-deviation bounds | **Must be reviewed** | Live oracle cadence and chain-risk policy; no numeric value is specified here |
| Maximum premium rate | **Must be reviewed** | Deterministic safety ceiling; no numeric value is specified here |
| Quote validity window | **Must be reviewed** | The quote must be short-lived and block-based; no exact TTL is specified here |
| Anthropic model ID, engine version, environment, corpus path | **Runtime configuration** | Deployment/operator configuration, not model evidence |

The implementation names these runtime settings in `.env.example` and refuses
to start without the controls it needs. Blank values are intentional until the
benchmark and parameter review produce them. The required corpus artifact is
`bench/data/corpus.jsonl`, containing the 150–250 labelled scenarios required by
§5.4; it does not exist until those scenarios and their source citations have
been assembled.

### 5.3 The honest problem: no loss history

Aave on X Layer has months of history and zero incidents. There is no local base
rate. Pretending otherwise would be the single worst thing this project could do.

**How it is handled, and stated openly:**

- Base hazard is derived from Aave V3's record **across all deployments** —
  years of history, many chains, known incidents, audit coverage — not from the
  X Layer instance alone.
- That extrapolation carries an explicit **uncertainty loading**, sized by how
  little local data exists and shrinking as this deployment ages.
- The README states, in plain words: *this is a cross-deployment extrapolation,
  here is the loading it carries, and here is how it decays with local
  observation.*

An agent that priced this confidently would be wrong. An agent that prices it
with a stated loading and declines when the loading exceeds a bound is doing the
job correctly. That distinction is the entire quantitative argument of the
submission — make it explicit.

### 5.4 Calibration — the required artifact

Anyone can claim their model works. Almost nobody measures whether its
confidence means anything.

Build `bench/` with 150–250 labelled scenarios: historical protocol-risk
situations across DeFi with known outcomes — incidents that occurred, and
comparable situations that did not. Sources: published post-mortems, audit
findings, incident databases, protocol governance records.

Report, publicly, in the README:

| Metric | Why it matters |
|---|---|
| **Verdict accuracy** | Baseline competence |
| **Accuracy on quotes issued** | The number that matters — what did it get wrong when it *did* commit capital? |
| **Refusal precision** | When it declined, was declining correct? |
| **Calibration curve** | Bin by stated confidence, plot against observed accuracy. Is confidence monotonic? By how much is it overconfident? |

**Derive the gate threshold from this curve, not from intuition**, and publish
`bench/threshold-derivation.md` showing the working:

1. Bin by stated confidence; plot stated vs observed.
2. Confirm monotonicity. If confidence is not monotonic with accuracy, it is not
   a usable signal and the README must say so.
3. Measure the overconfidence offset.
4. Choose the operating point by cost asymmetry: **a wrong quote commits capital
   against a risk you mispriced; a wrong refusal is a lost sale.** Underpricing
   is unrecoverable; declining is not. Set the threshold where accuracy-on-quotes
   clears the bar.
5. State the resulting threshold, the offset it corrects for, and what it buys.

Write the sentence explicitly: *the threshold was not chosen, it was measured.*

### 5.5 Continuous operation

A keeper reprices every covered reserve on a schedule and posts each decision —
quote or refusal — to `PricingRegistry`. By submission there are hundreds of
real, timestamped, independently replayable pricing decisions on X Layer.

This is what makes the agent visibly autonomous rather than a demo endpoint. It
also produces the live data behind the calibration story.

---

## 6. Demonstrating a payout that has not happened

The headline mechanism — a claim paying out — will not fire during the judging
window, because Aave will not be exploited on schedule. This is the single
largest presentation risk and it has a clean solution.

### 6.1 Fork test — the primary artifact

Foundry forks X Layer mainnet at a live block. The Aave contracts are the real
deployed ones. The state is real. Only the failure is induced.

```
test/fork/ClaimPayout.t.sol
```

```solidity
function test_DeficitTriggersPayout_OnForkedMainnet() public {
    vm.createSelectFork(XLAYER_RPC, BLOCK);
    // real Aave contracts, real reserve state, real balances
    // 1. capital provider funds CoverPool
    // 2. user deposits through xCoverVault, receives policy
    // 3. induce a deficit in the forked state
    // 4. ClaimResolver.evaluate() → Claimable
    // 5. claim() → user is made whole
    // assert exact payout arithmetic
}
```

A judge runs `forge test --match-path test/fork/*  --fork-url $XLAYER_RPC` and
watches it pass. **A reproducible test is stronger evidence than a video.**

On screen, state exactly what it is: *"Forked X Layer mainnet at block N. Real
Aave contracts. Induced deficit. Real claim logic. Real payout arithmetic."*
Never blend it with live figures.

### 6.2 Live product alongside

Simultaneously, on mainnet: a real capital provider deposit, a real covered
position, premium streaming block by block, and pricing decisions accumulating
in `PricingRegistry`. Small real numbers.

Two clearly separated panels in the UI and the demo:

- **Live — mainnet.** Cover active, premium accruing, decisions accumulating.
- **Simulated — forked mainnet.** What happens when it fires.

Distinct visual treatment. Distinct labels. Never merged, never ambiguous.

---

## 7. Frontend

### 7.1 The constraint

X Layer has publicly noted that submissions were offline or non-functional
during review. Judging happens asynchronously, possibly at 3am, with no operator
awake.

- Uptime monitoring from first deploy through 31 August.
- A judge completes a meaningful flow unaided.
- No step requires anyone to be available.

### 7.2 Views

**Deposit** — enter an amount, see the live quote appear (premium rate, cover
amount, net yield after premium), deposit in one action. If the agent declines,
show the reason and the cited concerns — do not show a generic error.

**Position** — cover amount, premium paid to date, accruing yield, net position,
covered events with their exact triggers, waiting period status.

**Capital provider** — supply capital, see locked vs free, premium income to
date, outstanding cover, and the solvency ratio drawn against its floor.

**Decision viewer** — public, no wallet required. Paste or link a
`decisionHash`, see the full decision JSON, the recomputed hash, and the
on-chain commitment side by side with a match indicator. **This is the most
persuasive screen in the product.** Give it real design attention.

**Live activity** — the continuous pricing feed, quotes and refusals
accumulating with links to X Layer.

**Protocol panel** — surfaced prominently, every figure read from chain state,
never from a database:

- Capital in pool · outstanding cover · solvency ratio vs floor
- Total value covered on X Layer
- Pricing decisions committed (running count)
- Active policies · premium distributed to date
- Current premium rate, live

### 7.3 Demo narrative — three beats, in this order

**Beat 1 — the refusal.** Request cover under conditions the agent cannot price:
insufficient evidence, or a reserve where the deficit is already non-zero. It
declines, with cited reasoning. Say the line: *an agent that always quotes is an
agent that will eventually underprice a catastrophe.*

**Beat 2 — the bundled deposit.** One transaction. Deposit, and the position is
covered. Show that the user never made a separate decision to buy protection —
which is precisely why almost nobody has protection today.

**Beat 3 — the payout.** Run the fork test live on screen. Real contracts,
induced failure, user made whole. Labelled as a simulation throughout.

Lead with the refusal. Close with the payout. The successful quote in the middle
is the least interesting of the three because it is what everyone expects.

---

## 8. Schedule

| Day | Work | Milestone |
|---|---|---|
| **1** | Repo scaffolded. **Run all §3.3 verification calls; record raw output. Check whether Aave exists on X Layer testnet (§3.5).** Foundry project; `VerifyIntegration.s.sol` passing. X account created, first post. | `getReserveDeficit` confirmed or fallback decided; testnet venue strategy settled |
| **2** | `CoverPool` + `CoverPolicy` with full test suite. Solvency invariant test fuzzing arbitrary sequences. `IYieldVenue` interface + `TestnetVenue`. **Deploy X Layer testnet, full set.** | Invariant test green; testnet addresses recorded with timestamps |
| **3** | `xCoverVault` (ERC-4626) + `AaveV3Venue` integrated against real Aave on a fork. `ClaimResolver` with all three triggers and block sampling. Full lifecycle exercised on testnet including a judge-triggerable claim. | Deposit → venue → policy working on fork and on testnet |
| **4** | Pricing agent: read, retrieve, assess, compute, gate. `PricingRegistry`, decision canonicalisation, hashing, public replay endpoint. | First real signed quote posted on testnet |
| **5** | Benchmark corpus built and scored. Calibration curve. `bench/threshold-derivation.md`. Gate threshold set from the data. **Deploy X Layer mainnet.** | Published metrics; mainnet live after testnet |
| **6** | `test/fork/ClaimPayout.t.sol` passing. Frontend: deposit, position, capital provider views. Real capital deposited; real covered position opened on mainnet. | Fork test green; live position on mainnet |
| **7** | Decision viewer, live activity, protocol panel. Continuous pricing keeper running. Uptime monitoring. README, architecture diagram, growth plan, limitations. | Judge can complete a flow unaided |
| **8** *(20 Aug)* | Demo video. X post mentioning **@XLayerOfficial**. **Submit.** | Submitted a day early |

Submit on the 20th, not the 21st. Never submit on deadline day.

Note: this schedule is planning context only. It must never leak into commit
messages — see §1.4.

**Contingency order if forced** — reduce benchmark size (never drop it), then
simplify the capital-provider UI, then reduce keeper frequency. **Never reduce:**
the solvency invariant test, the fork payout test, the three separation tests,
the refusal path, the testnet→mainnet sequence.

---

## 9. X Layer submission requirements

Hard requirements. Failing any one disqualifies regardless of quality.

- [ ] AI incorporated into the product design
- [ ] Deployed to X Layer **testnet**, then **subsequently** to mainnet — the
      sequence is required and must be provable by timestamps
- [ ] Dedicated X account, kept active throughout — create day 1, post daily
- [ ] At submission, that X account posts and mentions **@XLayerOfficial**
- [ ] Google Form submitted by **21 August 2026, 23:59 UTC**

Judging criteria, and where each is answered:

| Criterion | Evidence |
|---|---|
| Application of AI | Grounded assessment, ensemble disagreement as signal, refusal gate, published calibration, threshold derived from measurement |
| Innovation | Cover bundled at deposit; agent-priced underwriting; parametric trigger read directly from protocol accounting |
| Product completeness | Live mainnet, real capital, real position, fork-proven payout, full test coverage |
| User value | Depositors on X Layer currently have no way to price or transfer this risk |
| Integration with X Layer | Native throughout: Aave integration, USDT settlement, all state on X Layer |
| Growth potential | Eight further reserves; wrapped-asset cover as a distinct product; other venues as they deploy |
| Ecosystem contribution | Cover increases the amount of capital willing to sit in X Layer DeFi; capital pool and premium flow are X Layer TVL |

**Ship a one-page growth plan as a deliverable.** Growth potential and ecosystem
contribution are two of seven criteria and most submissions address neither.

---

## 10. Honest limitations — state these, do not hide them

Naming a real constraint reads as rigor. Having one discovered reads as
concealment.

1. **No local loss history.** Pricing extrapolates from Aave V3's
   cross-deployment record with an explicit uncertainty loading. Stated, sized,
   and decaying with local observation.
2. **Small capital base.** Full collateralization means cover capacity is capped
   by pool size. This is a capital constraint, not a design flaw. The path to
   scale is more capital providers and, later, a second-loss tranche.
3. **Correlated risk.** One exploit hits every policy simultaneously. Full
   collateralization is the answer; fractional reserving would not be.
4. **Narrow scope.** One reserve, one venue, three defined events. Deliberate.
   Depth over breadth.
5. **No third-party audit.** Test coverage and invariant testing are not an
   audit. Say so.
6. **Regulatory.** This is cover, not insurance, and a production version would
   need proper structuring. Use the category's established language throughout.

---

## 11. Definition of done

- [ ] §3.3 verification run; raw output committed to `docs/chain-verification.md`
- [ ] `VerifyIntegration.s.sol` passing in CI
- [ ] Solvency invariant proven by Foundry fuzz across arbitrary call sequences
- [ ] `test_PricerCannotMovePoolFunds` passing
- [ ] `test_PricerCannotAlterClaimOutcome` passing
- [ ] `test_AdminCannotDenyValidClaim` passing
- [ ] Test asserting `CoverPool` capital is never supplied to a covered reserve
- [ ] Test asserting pause blocks issuance but never claims or withdrawals
- [ ] `test/fork/ClaimPayout.t.sol` passing against forked X Layer mainnet
- [ ] Deployed X Layer testnet, then mainnet, sequence provable
- [ ] `deployments/xlayer-testnet.json` and `deployments/xlayer-mainnet.json`
      committed with addresses, tx hashes, block numbers, timestamps
- [ ] `docs/deployments.md` states the venue difference plainly
- [ ] Test asserting `AaveV3Venue` exposes no `induceDeficit` surface
- [ ] Config loader throws when chain environment and venue implementation
      disagree
- [ ] A judge can trigger a claim themselves on testnet and watch it settle
- [ ] Real capital in the pool; real covered position; premium accruing on mainnet
- [ ] Pricing agent live; quotes and refusals accumulating in `PricingRegistry`
- [ ] Decision replay endpoint public; hash independently verifiable
- [ ] Benchmark published: verdict accuracy, accuracy-on-quotes, refusal
      precision, calibration curve image
- [ ] `bench/threshold-derivation.md` published with the working
- [ ] Frontend live; live and simulated clearly separated; every figure from chain
- [ ] A stranger completes a flow unaided with nobody awake
- [ ] Uptime monitoring through 31 August
- [ ] README: diagram, all addresses with explorer links, benchmark results,
      limitations, growth plan
- [ ] X account active; submission post mentions @XLayerOfficial
- [ ] Form submitted **20 August**
- [ ] Every commit authored as lightlabs, clean message, no AI attribution
- [ ] `PROGRESS.md` reflects reality

---

## 12. Day-one checklist

1. Run every command in §3.3. Record raw output with block numbers. Commit.
2. Scaffold the monorepo; Foundry project; `VerifyIntegration.s.sol`.
3. Write the solvency invariant test **before** `CoverPool` — the invariant
   defines the contract, not the reverse.
4. Create the X account; publish the first build post.
5. Start the benchmark corpus. It is the long-lead item, it gates the threshold,
   and the threshold gates everything downstream.
