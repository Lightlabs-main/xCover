# xCover

Depositor cover for Aave V3 on X Layer, priced per-block by an agent that may
decline to quote, minted in the same transaction as the deposit.

> xCover lets a depositor on X Layer supply to Aave and receive protection for
> that position in the same transaction, priced continuously by an agent that
> declines to quote when it cannot price the risk honestly.

**Status: in development.** This README describes what exists today and states
plainly what does not. See [Build status](#build-status) before reading anything
here as a working system.

---

## The problem

Every depositor in an Aave reserve carries risk they did not choose and cannot
price: contract failure, oracle failure, and liquidity conditions that prevent
withdrawal. They are given a yield number. They are given no risk number.

Cover for this risk already exists, and has not been widely adopted. Two
structural reasons, both addressable:

**Cover is sold separately from the deposit.** A second decision, a second
transaction, a second fee, taken at the moment the user is least worried. Almost
nobody makes it. The fix is to make cover a property of the position rather than
a product bought alongside it.

**Cover is priced by hand.** Underwriters set prices manually in governance
forums. Prices go stale, do not respond to utilisation, and are never calibrated
against outcomes.

xCover addresses both: cover is minted with the deposit and paid for out of the
yield that deposit already earns, and the price is set per-block by an agent
reading live protocol state.

## What is covered

Every covered event is measurable by a contract call. If a human has to form a
judgement, it is not covered, and the terms say so.

| Event | Trigger | Measurement |
|---|---|---|
| **Reserve deficit** | Aave records bad debt in the covered reserve | `POOL.getReserveDeficit(asset) > 0` |
| **Redemption failure** | aToken fails to redeem within tolerance of 1:1 over a sustained window | Sampled on-chain over N blocks; tolerance and window fixed in the policy terms at mint |
| **Oracle failure** | Price source reports stale or implausible data over a sustained window | `AaveOracle` sampled over N blocks against defined staleness and deviation bounds |

Everything else is out of scope, listed in the terms, and shown in the UI at
purchase. Narrow and automatic beats broad and discretionary.

A single-block read is manipulable with a flash loan, so every trigger is
sampled across a window and must hold throughout it. N is fixed in the policy's
`termsHash` at mint and cannot be changed afterwards.

## What this is not

- **Not insurance.** "Cover", "protection", "discretionary mutual". A deliberate
  legal distinction, not a stylistic one.
- **Not protocol-level coverage.** xCover pays an individual depositor for their
  own loss. It does not repair Aave's balance sheet and does not reduce a reserve
  deficit.
- **Not a yield product.** Capital providers earn premium for bearing risk. That
  is underwriting, not farming.

---

## How it works

```
                    ┌──────────────┐
   deposit USDT ───►│  xCoverVault │───► supply to Aave, receive aUSDT
                    │  (ERC-4626)  │───► request quote  ─────┐
                    └──────┬───────┘                         │
                           │                                 ▼
                           │                        ┌─────────────────┐
                           │                        │ PricingRegistry │
                           │                        │  signed quotes  │
                           │                        │  and refusals   │
                           │                        └─────────────────┘
                           ▼
                    ┌──────────────┐      reserveCover      ┌───────────┐
                    │ CoverPolicy  │───────────────────────►│ CoverPool │
                    │  (ERC-721)   │◄───────────────────────│  capital  │
                    └──────┬───────┘        payClaim        └───────────┘
                           │                                      ▲
                           ▼                                      │
                    ┌──────────────┐                              │
                    │ ClaimResolver│──────────────────────────────┘
                    │ deterministic│
                    └──────────────┘
```

One transaction. The user makes one decision — deposit — and receives a covered
position. Premium streams out of accrued yield; there is no recurring payment to
forget.

**If no valid quote is available** — the agent declined, or the pool lacks
capacity — the deposit reverts with a clear reason. It does not silently deposit
without cover. A user believing they are protected when they are not is the worst
failure this system could produce.

### Solvency is the product

```
capital >= outstandingCover
```

Full collateralization, not fractional. Traditional insurers reserve
fractionally because they rely on the law of large numbers across uncorrelated
risks. These risks are perfectly correlated — one exploit triggers every policy
at once — and the book is small. Full backing is the only honest choice, and it
means the pool cannot become insolvent.

Any policy mint that would breach the invariant reverts. Not queued, not
partially filled.

This is proven by a Foundry invariant fuzz across arbitrary call sequences, not
asserted in a comment. Two suites:

- `test/invariant/CoverPoolSolvency.t.sol` — the pool's own accounting.
- `test/invariant/CoverSystemSolvency.t.sol` — the same property driven through
  the real issuance path, plus the property that binds the two contracts: *a
  policy holds a pool reservation if and only if it is Active or Claimable.*

Each checks three properties after every call: cover is backed by capital,
capital is backed by tokens actually held, and the obligation total equals the
sum of its parts, recomputed from scratch.

Both suites have been mutation-checked — the enforcement deliberately removed, to
confirm the tests fail — because an invariant that has never been seen to fail is
not evidence.

### The payout test

`test/fork/ClaimPayout.t.sol` is the primary artifact, and it is worth being precise
about what it does and does not demonstrate.

**Real:** the Aave Pool, the oracle, the USDT and aUSDT contracts, at the addresses
verified in `docs/chain-verification.md`. The covered position is genuinely supplied
to Aave. Observations are read out of Aave's own storage through its own getter. The
trigger is evaluated by the deployed Aave bytecode, unmodified. The payout moves real
USDT to the policy holder, and the pool is asserted solvent afterwards.

**Synthetic, and stated rather than hidden:** X Layer's USDT reserve is healthy — no
deficit, at peg, deeply liquid. A test cannot cause a real bad-debt event, and waiting
for one is not a strategy. So the deficit value is written directly into the live
Pool's storage on the fork. The number is planted; everything reading and reacting to
it is real. **This test does not show that a deficit occurred on X Layer.**

The storage slot is discovered at runtime — record which slots `getReserveDeficit`
reads, write to each until Aave's own getter reports the value back — rather than
hardcoded. A hardcoded slot would silently target the wrong field after any Aave
upgrade. This fails loudly instead.

Two further properties are asserted on the fork: a deficit that clears for even one
block inside the window does not pay, and the claim leaves both the depositor's
underlying position and Aave's own deficit untouched.

### The agent prices; it never moves money

The model proposes a premium and a risk assessment. It never mints a policy,
approves a claim, or releases a payout. Every transition that touches value is
executed by deterministic code after deterministic checks pass, and the
separation is enforced by contract roles rather than by convention:

| Role | May do | May not do |
|---|---|---|
| `PRICER_ROLE` | Submit signed quotes and refusals | Touch pool funds or claim outcomes |
| `KEEPER_ROLE` | Trigger evaluation and settlement | Alter any outcome |
| `ADMIN_ROLE` | Pause **new issuance** | Block a claim or a withdrawal |

Pausing never blocks claims or withdrawals. A user's ability to be paid, or to
exit, does not depend on anyone's cooperation.

### Refusal is a first-class outcome

`DECLINE_TO_QUOTE` is a correct, successful result, not a failure to paper over.
It is logged, hashed, committed on-chain in `PricingRegistry`, and surfaced in
the UI with the same prominence as a quote. An agent that always quotes is an
agent that has not understood the problem.

Every pricing decision — including every refusal — is committed on-chain as a
hash of its canonical JSON. The full decision is served publicly, so anyone can
fetch it, canonicalise it (RFC 8785), hash it, and confirm it matches what the
contract recorded.

### Adverse selection controls

Both live in the contracts, not in the pricing model — a control the model can be
talked out of is not a control.

- **Waiting period.** Cover does not activate until `startBlock + waitingPeriod`.
  Without it, anyone who sees trouble coming buys cover immediately beforehand.
- **Per-reserve daily cap.** New cover written per reserve per day is bounded, so
  the same insight cannot be scaled up arbitrarily within a day.

### Reflexivity

`CoverPool` capital is never supplied to the reserve it covers. If it were, the
collateral would lose value at precisely the moment claims trigger — the failure
that broke first-generation cover protocols. This is enforced in code, not
documented as a policy: the pool holds no approval to the Aave Pool for a covered
reserve, and there is a test asserting it.

---

## Build status

Honest state of the repository. Nothing is called done until it has run end to
end against a real dependency on a real chain.

| Component | State |
|---|---|
| Chain verification against live X Layer mainnet | Done — raw output in `docs/chain-verification.md` |
| `VerifyIntegration.s.sol` | Passing against live mainnet |
| `CoverPool` | Written; solvency invariant passing and mutation-checked |
| `CoverPolicy` | Written; full lifecycle under unit test |
| `PricingRegistry` | Written; quotes and refusals unit tested |
| Separation tests (§4.7) | All five written and passing |
| `IYieldVenue` / `TestnetVenue` | Written; unit tested |
| `AaveV3Venue` | Written; **passing against forked X Layer mainnet with real Aave** |
| `ClaimResolver` | Written; **full payout passing against forked mainnet with real Aave**; bounded-cadence sampling now enforced |
| `xCoverVault` | Written; covered deposit and every refusal path unit tested; direct share transfers disabled until atomic position transfer exists |
| Pricing agent | Not written |
| Benchmark corpus and calibration | Not started |
| Frontend | Not started |
| Deployment scripts | Written; shared wiring, mainnet gated on the testnet record existing |
| **X Layer testnet (1952)** | **Corrected deployment and lifecycle proof complete** at block 38581492; a 2,500 tUSDT deficit paid 2,500 tUSDT pro rata. See [`docs/deployments.md`](docs/deployments.md) |
| X Layer mainnet (196) | Not deployed |

Two things have run against real Aave on a mainnet fork. `AaveV3Venue` supplies real
USDT, receives real aUSDT, accrues real interest (11.977953 USDT on 50,000 over 30
days at the forked block), and redeems in full. And `test/fork/ClaimPayout.t.sol`
runs the whole path — deposit, cover, trigger, settlement — paying 50,000 USDT to the
policy holder. See [The payout test](#the-payout-test) for exactly what is real in it
and what is not.

**The corrected full contract set is deployed on X Layer testnet (chain 1952)** at
block 38581492. The live run completed underwriting capital, a signed quote, a
covered deposit, a refusal, a real 2,500 tUSDT write-off, five observations at
20-block gaps, a `ReserveDeficit` evaluation and a 2,500 tUSDT payout. What testnet
cannot show is the Aave integration, because Aave V3 is not deployed there — that
is what the fork tests cover. Mainnet is not deployed yet.

## Verified integration facts

Verified 2026-08-17 against live X Layer mainnet at block 68179960. Full evidence
with block numbers in `docs/chain-verification.md`.

| Network | RPC | Chain id |
|---|---|---|
| X Layer mainnet | `https://rpc.xlayer.tech` | 196 |
| X Layer testnet | `https://testrpc.xlayer.tech` | 1952 |

The testnet chain id is **1952**. 195 is listed as deprecated.

| Contract (mainnet) | Address |
|---|---|
| Aave `POOL` | [`0xE3F3Caefdd7180F884c01E57f65Df979Af84f116`](https://www.oklink.com/x-layer/address/0xE3F3Caefdd7180F884c01E57f65Df979Af84f116) |
| `POOL_ADDRESSES_PROVIDER` | [`0xdFf435BCcf782f11187D3a4454d96702eD78e092`](https://www.oklink.com/x-layer/address/0xdFf435BCcf782f11187D3a4454d96702eD78e092) |
| `ORACLE` | [`0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6`](https://www.oklink.com/x-layer/address/0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6) |
| `USDT` (6 dp) | [`0x779Ded0c9e1022225f8E0630b35a9b54bE713736`](https://www.oklink.com/x-layer/address/0x779Ded0c9e1022225f8E0630b35a9b54bE713736) |
| `USDT_A_TOKEN` | [`0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297`](https://www.oklink.com/x-layer/address/0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297) |

What the verification settled:

- **`getReserveDeficit` exists and returns cleanly.** The reserve deficit trigger
  is buildable as specified; the redemption-failure fallback is not needed as the
  primary condition.
- **The USDT reserve is active, unfrozen, 6 decimals, ~50.2M supplied.** Cover is
  written against a reserve with real depositors, not an empty deployment.
- **The oracle reads $0.99896524.** Normal conditions are already ~10 bp off peg,
  so a depeg threshold must clear that or it fires on noise.
- **Aave V3 is not deployed on X Layer testnet** — empty code at both `POOL` and
  `POOL_ADDRESSES_PROVIDER`. A swappable `IYieldVenue` is therefore required, not
  optional: `TestnetVenue` backs testnet, `AaveV3Venue` backs mainnet.

Launch covers **USDT only** — the deepest stable reserve, payout and covered
asset share a denomination so there is no FX exposure in the claim, and one
reserve keeps the correlation surface small enough to reason about honestly.

## Limitations

Stated here rather than left for a reviewer to find.

- **No loss history exists for this market.** The pricing model extrapolates from
  protocol-risk priors; it is not fitted to realised claims. Any confidence
  number it produces is meaningful only against its published calibration curve.
- **The testnet deployment has no live Aave behind it,** because Aave is not
  deployed on X Layer testnet. The venue backing each deployment is stated
  explicitly in `docs/deployments.md`.
- **Covering one reserve on one protocol is a small correlation surface by
  design, not by accident.** The wrapped reserves carry an additional bridge
  failure mode and are deliberately out of scope.
- **Exits are all-or-nothing.** A partial exit would leave a policy sized for a
  position that no longer exists, and resizing means re-quoting at exit time —
  exactly when someone who has seen bad news would want a new price. Closing a
  position returns the whole position.
- **One open covered position per address.** A second deposit must follow an exit.
- **Premium is owed whether or not the venue produced yield to pay it.** On
  mainnet it comes out of Aave interest. On testnet, where there is no yield
  source, it comes out of principal.
- **Full collateralization caps capacity.** Cover written can never exceed
  capital supplied. That is the trade being made: capacity for the guarantee that
  the pool cannot fail to pay.

## Repository

```
docs/SPEC.md                      binding specification
docs/chain-verification.md        raw on-chain evidence with block numbers
packages/contracts/               Foundry project, solc 0.8.28
  src/CoverPool.sol               capital and solvency accounting
  src/CoverPolicy.sol             ERC-721 policy positions and lifecycle
  src/PricingRegistry.sol         signed quotes and refusals
  src/ClaimResolver.sol           deterministic triggers and settlement
  src/xCoverVault.sol             deposit and cover in one transaction
  src/venues/AaveV3Venue.sol      supplies to real Aave V3 (mainnet)
  src/venues/TestnetVenue.sol     custody only, no yield source (testnet)
  src/XLayerAddresses.sol         verified addresses
  test/invariant/                 solvency invariants
  test/separation/                model-and-money separation tests
  test/fork/                      tests against forked X Layer mainnet
  script/VerifyIntegration.s.sol  asserts the integration still holds
deployments/                      per-chain address records
bench/                            benchmark corpus and threshold derivation
```

## Running it

Foundry is required.

```bash
git clone --recurse-submodules https://github.com/Lightlabs-main/xCover.git
cd xCover && pnpm install
cd packages/contracts

forge build
forge test

# Confirm the live Aave integration still holds.
forge script script/VerifyIntegration.s.sol --rpc-url https://rpc.xlayer.tech
```

The last command must print `All integration assumptions hold.` If it reverts, an
on-chain assumption has changed; read the failing require before doing anything
else.

## Licence

MIT.
