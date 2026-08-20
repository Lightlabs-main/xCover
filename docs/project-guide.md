# xCover project guide

## AI pricing for Aave V3 depositor cover

xCover is an AI pricing agent connected to Aave V3 on X Layer. It reads live
reserve conditions, retrieves cited risk evidence, evaluates a USDT position,
and returns a signed cover price or a signed refusal.

When a depositor accepts a price, xCover routes the USDT into Aave V3 and creates
the cover position in the same final transaction. A separate USDT underwriting
pool supplies the capital that stands behind the cover.

This guide explains the complete product in the order a new reader needs it:

1. what the AI agent does;
2. what a depositor receives;
3. how a depositor opens a position;
4. how underwriting capital works;
5. how cover becomes active and can pay;
6. how a position exits; and
7. how the contracts keep those responsibilities separate.

## The product in one minute

There are two participants and one decision engine.

### Aave V3 depositor

A depositor brings USDT to xCover. The AI pricing agent evaluates the current
Aave V3 reserve and produces a signed decision. After the decision is recorded,
the depositor opens a covered position. The USDT is supplied to Aave V3 through
the xCover vault, and the depositor receives vault shares and a cover policy.

### Underwriter

An underwriter adds USDT to the xCover pool. The pool issues shares that represent
the underwriter's share of pool capital. That capital backs covered positions and
is locked as new cover is written. Premium paid by covered positions returns to
the pool.

### AI pricing agent

The agent is the risk-pricing layer. It reads the live reserve, gathers cited
evidence, produces structured assessments, calculates a per-block premium rate,
and signs the result. It can return either:

- `QUOTE`: a price that can be recorded and used for a covered deposit; or
- `DECLINE_TO_QUOTE`: a signed decision explaining why the position cannot be
  priced under the current conditions.

The agent does not hold pool funds, call claim settlement, or choose who gets
paid. The contracts verify the signed decision and control all money movement.

## The complete architecture

```text
                         live Aave V3 state
                                  │
                                  ▼
                        ┌────────────────────┐
                        │  AI pricing agent  │
                        │ evidence + risk    │
                        │ price or refusal   │
                        └─────────┬──────────┘
                                  │ signed decision
                                  ▼
                        ┌────────────────────┐
                        │  PricingRegistry   │
                        │ decision + hash    │
                        └─────────┬──────────┘
                                  │ consumed by the vault
                                  ▼
 Depositor USDT ───────►┌────────────────────┐
                        │    xCoverVault     │
                        │ shares + position  │
                        └─────────┬──────────┘
                                  │ supplies depositor assets
                                  ▼
                        ┌────────────────────┐
                        │   AaveV3Venue      │
                        │  Aave V3 Pool      │
                        └────────────────────┘

 Underwriter USDT ─────►┌────────────────────┐
                        │    CoverPool       │
                        │ capital + backing  │
                        └─────────┬──────────┘
                                  │ reserves capital for each policy
                                  ▼
                        ┌────────────────────┐
                        │   CoverPolicy      │
                        │ policy + lifecycle │
                        └─────────┬──────────┘
                                  │ sampled reserve conditions
                                  ▼
                        ┌────────────────────┐
                        │  ClaimResolver     │
                        │ evaluate + settle  │
                        └────────────────────┘
```

The depositor asset and underwriting asset are intentionally separate:

- the depositor's USDT is supplied to Aave V3 and becomes the covered position;
- the underwriter's USDT stays in `CoverPool` and is available to pay valid
  claims; and
- `CoverPool` is never supplied into the Aave V3 reserve it covers.

That separation prevents the capital backing a claim from losing value in the
same reserve at the same time as the claim event.

## What the AI pricing agent does

The AI work is the core product layer. The agent is not a generic chat helper
and it does not sit in front of a fixed DeFi rate. It turns live protocol state
and cited risk evidence into a signed, replayable pricing decision.

### 1. It reads the live reserve

For the configured X Layer deployment, the agent records the current:

- chain and block;
- reserve and asset decimals;
- total supplied amount;
- reserve deficit;
- Aave oracle price;
- redeemable liquidity;
- utilization and borrow state when available;
- reserve configuration, including active and frozen flags;
- venue assets; and
- pool capital and outstanding cover.

The complete chain snapshot is written into the decision document. A reviewer
can see which block the agent used instead of receiving an unexplained number.

### 2. It retrieves cited evidence

The agent retrieves relevant entries from the committed risk corpus. Each entry
has a source URL, title, date, protocol, outcome, and excerpt. The source IDs are
carried into the decision document so the reasoning can be inspected later.

The corpus is evidence for the assessment. It does not get to override live
chain conditions or contract controls.

### 3. It performs two assessments

The service runs two differently framed structured assessments. Each assessment
returns:

- a base hazard estimate per block;
- an uncertainty loading;
- a confidence value;
- named risk factors and severity;
- concerns and missing facts;
- conclusions tied to evidence IDs; and
- the exact model label used for that assessment.

The service compares the two assessments. Their disagreement is itself a risk
signal. If they disagree beyond the configured bound, the service refuses to
price the position.

### 4. It computes the price in deterministic code

The AI supplies risk inputs. Deterministic code converts those inputs into the
per-block premium rate. The computation applies:

- the average base hazard;
- a utilization multiplier;
- a concentration multiplier based on the requested cover and pool capital;
- an uncertainty multiplier;
- a reviewed capital-cost margin; and
- the configured safety limits.

The result is a `premiumRateRay`, the fixed-point per-block rate stored in the
signed decision and the cover policy.

### 5. It applies refusal gates

The agent refuses instead of inventing a price when a required condition fails.
The gates include:

- missing live chain facts;
- an empty evidence set or unavailable assessment;
- an existing reserve deficit;
- a reserve with no supplied assets;
- utilization above the allowed level;
- insufficient underwriting capital;
- an inactive or frozen reserve;
- an invalid, stale, zero, or conflicting oracle reading;
- a price below the configured depeg bound;
- assessment disagreement above the bound;
- confidence below the configured threshold;
- uncertainty above the bound;
- a premium above the safety ceiling; or
- a zero computed rate without a valid reason to quote.

A refusal is a successful product result. It is signed, hashed, recorded, and
shown to the user with its reasons.

### 6. It signs a canonical decision

The service creates a canonical JSON decision document and hashes it. It signs a
typed decision containing:

- the reserve;
- the requested cover amount;
- the premium rate;
- the last valid block;
- whether the decision is declined;
- the document hash;
- the engine version; and
- a nonce.

`PricingRegistry` verifies this signature and stores the decision on X Layer.
The vault later consumes the decision by its hash. A decision cannot be reused,
changed, or silently substituted for a different amount.

### 7. Calibration status

Pricing calibration is in progress. The live service uses explicit operating
controls while the evidence is being turned into a measured threshold. The
decision document records this state. No measured confidence threshold is
presented as if it were already established.

This keeps the AI work visible without allowing an unmeasured confidence value
to control a money-moving transaction by implication.

## What a depositor receives

After a successful covered deposit, the wallet has a position represented by
several connected records.

### 1. An Aave-backed vault position

The user's USDT is supplied to the real Aave V3 Pool on X Layer through
`AaveV3Venue`. Aave issues its interest-bearing reserve token to the venue. The
venue reads that balance live, so accrued Aave interest is included in the
position's current value.

The user does not receive the Aave reserve token directly in the wallet. The
xCover vault holds the Aave position and issues xCover vault shares that
represent the user's share of the live position.

### 2. xCover vault shares

`xCoverVault` is an ERC-20 vault with the symbol `xcUSDT`. The shares represent a
proportional claim on the assets held by the venue, including accrued value.

Shares are minted to the receiver in `depositCovered` and burned on `exit`.
They are currently non-transferable because the cover policy and the address-keyed
position record must move together. A future transferable design must move all
three records atomically.

### 3. An xCover Policy position

`CoverPolicy` mints an `XCOVER` policy for the receiver. The policy stores:

- the covered reserve;
- the covered amount;
- the start and end blocks;
- the waiting period;
- the per-block premium rate;
- the signed decision hash; and
- the fixed claim terms hash.

The policy is the cover record. It is also currently non-transferable so it
cannot become separated from the vault position.

### 4. A signed AI pricing record

The pricing decision is recorded in `PricingRegistry`. It links the position to:

- the AI assessment document;
- live chain facts at a named block;
- the evidence used;
- the deterministic computation;
- the final gate result; and
- the signature that the contract verified.

Accepted prices and refusals use the same public decision path.

### 5. Premium accounting from position value

The premium rate is fixed when the position opens and accrues per block. On
exit, the vault redeems the position from Aave V3, sends the accrued premium to
`CoverPool`, and returns the remaining assets to the user.

The user does not make a separate recurring premium payment. The premium is
settled from the value redeemed from the Aave-backed position.

### 6. Exit and claim tracking

The dashboard reads the user's policy, share balance, covered amount, premium
rate, and opening block. It also shows the public reserve readings and counters.

The user can exit the full position through the vault. If a covered event has
already made the policy claimable, the claim remains connected to the policy
holder while the position lifecycle is settled according to the contract rules.

Partial exits are not supported in this build because shrinking the position
would require resizing and re-pricing the policy at exit time.

## The depositor flow, step by step

The phrase “one transaction” refers to the final covered deposit transaction.
The wallet still performs approval and decision-recording transactions before
that final call.

### Step 1: Request a price

The dashboard sends the requested cover amount to the AI pricing service. This
is an API request, not a wallet transaction. The service reads the live chain,
retrieves evidence, assesses the position, applies gates, and returns a signed
decision.

### Step 2: Record the decision

The user submits the signed decision to `PricingRegistry.recordDecision`. The
registry verifies:

- the signer;
- the decision hash;
- the reserve;
- the requested amount;
- the expiry block; and
- whether the decision is a quote or refusal.

The registry stores it so the final deposit can consume exactly that decision.

### Step 3: Approve USDT

The user approves `xCoverVault` to transfer the selected USDT amount. This is a
normal token approval transaction.

### Step 4: Call `depositCovered`

The final transaction executes the full position creation:

1. The vault pulls USDT from the user.
2. The vault supplies that USDT to `AaveV3Venue`.
3. `AaveV3Venue` supplies it to the Aave V3 Pool.
4. The vault consumes the recorded decision.
5. `CoverPolicy` mints the policy.
6. `CoverPool` reserves the matching underwriting capital.
7. The vault records the position and mints `xcUSDT` shares.

If the decision is stale, declined, priced for another amount, or the pool,
daily cap, terms, or venue check fails, the transaction reverts as a whole. It
does not leave the user with an uncovered Aave deposit.

## The underwriting flow

Underwriting is the capital side of xCover.

### Add capital

Any wallet can:

1. approve USDT for `CoverPool`;
2. call `depositCapital`; and
3. receive pool shares.

The pool calculates shares from the capital already held and the total shares
already issued. It credits the amount actually received, not only the amount
requested.

### Back a covered position

When a covered position opens, `CoverPolicy` calls `CoverPool.reserveCover`.
The pool checks the central solvency rule:

```text
capital >= outstandingCover
```

If the new position would exceed free capital, issuance reverts. The pool never
creates an obligation without matching capital behind it.

### Track free and locked capital

- `capital` is all pool capital.
- `outstandingCover` is the amount promised to active policies.
- `freeCapital` is capital minus outstanding cover.

An underwriter can withdraw only the part of their share value that is within
free capital. Capital locked behind active cover cannot be withdrawn until the
policy expires, is cancelled, or is settled.

### Receive premium

When a depositor exits, the vault sends accrued premium to the pool. Premium
raises pool capital without raising its cover obligation, increasing the value
backing the provider shares.

### Withdraw capital

An underwriter burns pool shares with `withdrawCapital`. The amount returned is
bounded by both the value of those shares and the pool's current free capital.
Withdrawals and claim settlement remain available even when new issuance is
paused.

## How cover becomes active

A policy is not active from the first block. It has a waiting period stored in
the policy terms. The policy becomes active at its recorded start block plus the
waiting period and remains active until its end block, unless a covered event
changes its state first.

The waiting period prevents a user from seeing an imminent problem and buying
cover immediately before it is measured.

New cover is also limited by a daily per-reserve cap. This prevents a single
pricing decision or event from creating unlimited exposure in one day.

The terms are hashed when the policy is minted. The resolver requires the same
terms later, so thresholds cannot be changed after a loss appears.

## How claims are measured and paid

`ClaimResolver` is deterministic. It does not ask the AI agent, an administrator,
or a governance vote whether a claim should pay. It reads the recorded reserve
observations and compares them with the policy terms.

### Permissionless observations

Anyone can call `recordObservation`. The caller chooses when to take a reading,
but cannot choose the values. The resolver reads the venue at that block and
records:

- reserve deficit;
- oracle price;
- redeemable liquidity; and
- total supplied.

This lets any participant keep the observation history current. No single keeper
can stop a claim simply by going offline.

### Windowed conditions

A single block can be manipulated temporarily. The resolver therefore requires:

- enough observations;
- observations spanning the complete window;
- no observation gap above the allowed maximum; and
- a recent observation.

The condition must hold across the required window, not just in one favorable
block.

### Covered events

The current resolver evaluates three measurable conditions.

#### Reserve deficit

If the reserve deficit stays above the fixed deficit floor, the payout is the
depositor's pro-rata share of the measured reserve deficit, capped at the
covered amount.

#### Redemption failure

If redeemable liquidity stays below the required share of the covered amount,
the resolver treats the position as unable to redeem and computes a full covered
amount payout.

#### Oracle failure

If the reserve price stays below the fixed depeg bound, the payout is the
shortfall against the peg, capped at the covered amount. A partial depeg pays the
measured shortfall rather than treating the entire position as lost.

When more than one condition qualifies, the resolver uses the condition with the
largest computed payout. The payout is stored when the policy becomes claimable.

### Settle a claim

Once `evaluate` marks a policy claimable, anyone can call `claim`. The resolver
pays the policy holder, not the caller. `CoverPool.payClaim` reduces capital and
the outstanding obligation together, so the pool's solvency accounting remains
aligned with the payout.

## Role separation

The system deliberately separates AI pricing, depositor assets, underwriting
capital, and claim settlement.

| Component | Responsibility | Cannot do |
|---|---|---|
| AI pricing agent | Read evidence, price risk, sign prices or refusals | Move pool funds or settle claims |
| `PricingRegistry` | Verify and store signed decisions | Create a price by itself |
| `xCoverVault` | Route depositor USDT to Aave V3, create shares and policy | Open without a valid recorded decision |
| `CoverPool` | Hold underwriting capital and pay approved claims | Supply underwriting capital into Aave V3 |
| `CoverPolicy` | Store cover terms and lifecycle | Change fixed terms after mint |
| `ClaimResolver` | Read sampled conditions and settle valid claims | Ask the AI agent or administrator for permission |
| Dashboard | Show state and request wallet transactions | Custody keys or sign on behalf of a user |

The AI agent can influence the price and can refuse to quote. It cannot bypass
the contract solvency rule, approve a claim, withdraw a user's funds, or change
the cover terms.

## Mainnet and testnet venues

On X Layer mainnet, `AaveV3Venue` supplies the depositor's USDT to the real Aave
V3 Pool and reads the configured aToken and Aave oracle.

On X Layer testnet, Aave V3 is not deployed. `TestnetVenue` provides a custody
venue so the same xCover lifecycle can be exercised with test USDT. The contract
logic and resolver flow remain the same, but the testnet venue is not a live Aave
market.

The deployment identity is surfaced in the dashboard so a user can see whether
the current venue is Aave V3 or the test venue.

## What the dashboard shows

The public landing page explains the AI pricing product. The transaction
dashboard is opened separately so the public introduction is not cluttered with
wallet controls.

The dashboard reads and can show:

- network and venue;
- current block;
- AI pricing status;
- pool capital;
- free capital;
- open cover;
- Aave-backed vault assets;
- current reserve price;
- reserve liquidity and deficit;
- accepted, declined, and total decisions;
- pool shares;
- the connected wallet's USDT balance;
- the connected wallet's open policy; and
- the current covered amount, shares, premium rate, and opening block.

The wallet actions are:

- approve and add pool capital;
- withdraw pool shares;
- request a price;
- record the signed price;
- approve and open a covered deposit;
- exit the full position; and
- publish a current reserve observation.

## Current implementation state

- The AI pricing service is live on the X Layer mainnet deployment.
- Pricing calibration is in progress, and the live decision document records
  that state.
- The service uses explicit operating controls while calibration is in progress.
- The mainnet venue is the real Aave V3 Pool on X Layer.
- The underwriting pool must contain free capital before a quote can support a
  covered deposit.
- The standard uncovered vault entrypoints are disabled. A deposit must carry a
  recorded cover decision.
- One open position is supported per wallet.
- Full exit is supported; partial exit and direct position transfers require a
  future atomic position-transfer design.

## Where to read the implementation

| Area | Source |
|---|---|
| AI decision construction and gates | `packages/agent/src/decision.ts` |
| Live chain reads | `packages/agent/src/chain.ts` |
| AI provider boundary | `packages/agent/src/model.ts` and provider adapters |
| Signed decision storage | `packages/contracts/src/PricingRegistry.sol` |
| Aave V3 routing | `packages/contracts/src/venues/AaveV3Venue.sol` |
| Depositor vault | `packages/contracts/src/xCoverVault.sol` |
| Underwriting capital | `packages/contracts/src/CoverPool.sol` |
| Policy lifecycle | `packages/contracts/src/CoverPolicy.sol` |
| Claim measurement and settlement | `packages/contracts/src/ClaimResolver.sol` |
| Web dashboard | `apps/web/index.html`, `apps/web/app.js`, `apps/web/styles.css` |
| Calibration evidence | `bench/README.md` and `bench/threshold-derivation.md` |

## Running the project

From the workspace root:

```bash
pnpm --filter @xcover/pricing-agent build
set -a; source .env; set +a
HOST=127.0.0.1 PORT=8787 pnpm --filter @xcover/pricing-agent start
```

Open `http://127.0.0.1:8787/`. The landing page leads with the AI pricing
agent. Select **Open dashboard** to connect a wallet and use the live flows.
