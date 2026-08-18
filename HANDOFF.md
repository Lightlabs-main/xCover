# xCover — Session Handoff

Everything needed to resume work on xCover from a cold start, on any machine,
with no memory of previous sessions. Self-contained on purpose: paste this to a
fresh agent, or point one at this file in the repo.

**A Claude Code session loads `CLAUDE.md` automatically**, and that file points
here — so on a new codespace you do not need to explain any of this. Just say
what you want built. Read `CLAUDE.md` first if you are a human picking this up
cold; it is the short version of this document.

Repo: `https://github.com/Lightlabs-main/xCover`
Last updated: 18 August 2026 — 139 local tests passing; corrected source deployed and lifecycle-proven on X Layer testnet at block 38581492; mainnet not deployed

## Current checkpoint — resume here

The current working tree contains the correctness batch that has now been
broadcast and exercised end to end on X Layer testnet. The mainnet deployment
remains intentionally absent.

Done in source and tests:

- Mainnet `DeployMainnet` now binds `AaveV3Venue` to Aave's aggregate oracle,
  not the Chainlink-style USDT feed.
- `AaveV3Venue` ignores the caller-supplied aToken and reads liquidity and total
  supply from its immutable configured aToken. The live fork test passes with a
  bogus aToken address.
- Policy NFTs and vault shares are non-transferable. This is the safe current
  ownership model because `xCoverVault.positions` is address-keyed; transferability
  must wait for an atomic policy-plus-position transfer design.
- `ClaimResolver` now requires samples to cover the window, enforces a maximum
  observation gap and requires a fresh latest sample. Testnet is configured for a
  30-block maximum gap; mainnet for 60 blocks.
- `CoverPool` rejects a new capital epoch while zero-value legacy provider shares
  remain after a full payout.
- Testnet source parameters now use `liquidityFloorBps: 5000`, so the 25% demo
  deficit is not masked by the custody venue's redemption-failure trigger.

Verification completed:

- `forge build --force` passes.
- Full Foundry suite passes: **139 tests, 0 failures**.
- Live X Layer mainnet fork passes: **10 tests, 0 failures**.

Not yet done: build the pricing agent and benchmark corpus, review the remaining
reasoned parameters, fund and deploy mainnet, and finish the presentation layer.

---

## 0. Resume in a new codespace

```bash
git clone --recurse-submodules https://github.com/Lightlabs-main/xCover.git
cd xCover

# Foundry is not preinstalled on a blank codespace.
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc && foundryup

# Confirm the Aave integration still holds before writing anything.
cd packages/contracts
forge build
forge script script/VerifyIntegration.s.sol --rpc-url https://rpc.xlayer.tech
```

If that script prints `All integration assumptions hold.` the environment is
good. If it reverts, an assumption changed on chain — read the failing require
message and update `docs/chain-verification.md` before continuing. Do not work
around it.

`--recurse-submodules` matters: forge-std is a pinned submodule. If you forget
it, run `git submodule update --init --recursive`.

---

## 1. Standing instructions to whoever picks this up

Read `docs/SPEC.md` §1 first, every session. It is the single source of truth.
If code and spec disagree, one is wrong and it gets resolved explicitly, never
silently.

The short version of the absolute rules:

- No mocks standing in for real dependencies in anything presented as working.
- Deterministic code controls money. The agent prices; it never moves funds and
  never decides a claim.
- Refusal is a first-class outcome. `DECLINE_TO_QUOTE` is correct behaviour when
  data is insufficient, not a failure to paper over.
- Nothing is "done" until it has run end to end at least once against a real
  dependency on a real chain.

Working agreement: propose the interface before implementing it; run the full
test suite after significant changes and report failures honestly; update
`PROGRESS.md` at the end of every session.

---

## 2. Git identity and commit rules — binding

```bash
git config user.name  "Lightlabs-main"
git config user.email "lightlabs112@gmail.com"
```

Set these **locally on the repo** on any new machine. This identity matches the
account's other repositories. The `melindacharles@` account must never appear in
the history.

Commit messages: short imperative subject describing the change itself. No
phase numbers, no day numbers, no gate language, no emoji, no ticket prefixes,
no `Co-Authored-By`, no "Generated with", no tool or model name anywhere, ever.

```
good:  add solvency invariant test for CoverPool
       record X Layer chain verification output
       enforce quote freshness at policy mint

bad:   Phase 2: CoverPool ✅
       day 3 gate passed
       wip
```

**Why this is strict:** the submission is judged partly by automated reviewers
reading the git history.

### Pushing from a GitHub codespace — known trap

The ambient `GITHUB_TOKEN` environment variable is scoped to the codespace's own
repository. It is refused for git pushes to xCover *and* for Git Data API
writes, while still reporting `push: true` from the permissions endpoint — so it
looks like it should work and doesn't.

It also takes precedence over stored credentials. Fix:

```bash
GITHUB_TOKEN= gh auth login     # GitHub.com, HTTPS, browser. Needs `repo` scope.
GITHUB_TOKEN= git push origin main
```

Prefix git and gh commands with `GITHUB_TOKEN=` so the stored credentials in
`~/.config/gh/hosts.yml` win. Plain `gh auth login` will exit without prompting,
claiming you are already authenticated.

---

## 3. Verified chain facts

Full raw evidence with block numbers in `docs/chain-verification.md`. Verified
2026-08-17 at mainnet block 68179960. Re-verify before deploying; an address
book entry can go stale.

### Endpoints

| Network | RPC | Chain id |
|---|---|---|
| X Layer mainnet | `https://rpc.xlayer.tech` | `0xc4` = **196** |
| Mainnet fallback | `https://xlayerrpc.okx.com` | 196 |
| X Layer testnet | `https://testrpc.xlayer.tech` | `0x7a0` = **1952** |

**The testnet chain id is 1952, not 195.** 195 is listed on ChainList as
deprecated. Use 1952 in foundry config, frontend chain config, and every
deployment record.

Both networks rate limit to **100 requests/second/IP**. This constrains keeper
polling frequency — design for it rather than discovering it in production.

### What the verification settled

- **`getReserveDeficit(address)` exists on the Pool and returns cleanly** —
  returns `0`, no revert. This was the single blocking dependency. The reserve
  deficit trigger is buildable as specified and **the redemption-failure
  fallback is not needed as primary.** Do not build toward the fallback.
- **`POOL_REVISION` = 11**, consistent with Aave v3.3+ where
  `getReserveDeficit` was introduced. Corroborates the above.
- **Implementation behind the proxy is `0x5Bc7204274230a8F4778a35A58B776D16CF104b4`**,
  read from the ERC-1967 slot — matches the address book `POOL_IMPL`.
- **USDT reserve is active, unfrozen, 6 decimals**, LTV 7000, liquidation
  threshold 7500, reserve factor 1000.
- **aUSDT total supply ≈ 50,202,447 USDT** — real depositors, not an empty
  deployment. This is the denominator for any honest claim about what share of
  the reserve xCover covers.
- **Oracle live at `99896524`** = **$0.99896524** (8 decimals). Note: normal
  conditions are already ~10 bp off peg, so the depeg trigger threshold must sit
  well outside that or it fires on noise. Feed this into
  `bench/threshold-derivation.md`.
- **Aave V3 is NOT deployed on X Layer testnet** — empty code (`0x`) at both
  `POOL` and `POOL_ADDRESSES_PROVIDER`. Therefore `IYieldVenue` with a swappable
  implementation is **required, not optional**: `TestnetVenue` backs testnet,
  `AaveV3Venue` backs mainnet. `docs/deployments.md` must state this difference
  plainly rather than implying testnet has a live Aave integration behind it.

### Addresses (X Layer mainnet, chain 196)

Mirrored in `packages/contracts/src/XLayerAddresses.sol`.

| Contract | Address |
|---|---|
| `POOL` | `0xE3F3Caefdd7180F884c01E57f65Df979Af84f116` |
| `POOL_ADDRESSES_PROVIDER` | `0xdFf435BCcf782f11187D3a4454d96702eD78e092` |
| `POOL_CONFIGURATOR` | `0x1408b48B6A610948f04813EA6b2F438A6BBAd2f2` |
| `ORACLE` | `0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6` |
| `DATA_PROVIDER` | `0x6C505C31714f14e8af2A03633EB2Cdfb4959138F` |
| `POOL_IMPL` | `0x5Bc7204274230a8F4778a35A58B776D16CF104b4` |
| `USDT` (6 dp) | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |
| `USDT_A_TOKEN` | `0xF356ae412dB5df43BD3a10746f7ad4e1C4De4297` |
| `USDT_V_TOKEN` | `0x04837866D0cb0cd2D8F60fBCa83B4a24b3a7c8ac` |
| `USDT_PRICE_FEED` (Chainlink-style feed; not `IAaveOracle`) | `0x7ec7E5497EAf312FE82F8307D05eb0E5f0f157D3` |

Launch covers **USDT only** — deepest stable reserve, payout asset and covered
asset share a denomination so there is no FX exposure in the claim, and one
reserve keeps the correlation surface small enough to reason about honestly.

---

## 4. What exists right now

All five §4 contracts are written, with **139 tests passing** — 129 off-fork and 10
against live X Layer mainnet. The corrected X Layer testnet deployment is at block
38581492 and its lifecycle has paid the intended pro-rata deficit claim; mainnet is
not deployed.

```
README.md                        public-facing; states build status and limitations
CLAUDE.md                        auto-loaded entry point for a new session
docs/SPEC.md                     complete, binding, §1-12
docs/chain-verification.md       raw evidence, day-one verification
PROGRESS.md                      current state, next actions, session log
HANDOFF.md                       this file
packages/contracts/
  src/CoverPool.sol              capital, solvency accounting, premium, claims
  src/CoverPolicy.sol            ERC-721 positions, lifecycle, waiting period, daily cap
  src/xCoverVault.sol            deposit -> venue -> quote -> policy, one transaction
  src/ClaimResolver.sol          windowed trigger sampling and settlement
  src/PricingRegistry.sol        EIP-712 signed quotes and recorded refusals
  src/venues/AaveV3Venue.sol     real Aave V3 (mainnet)
  src/venues/TestnetVenue.sol    custody only, no yield source (testnet)
  src/interfaces/               ICoverPool, ICoverPolicy, IYieldVenue, IAaveV3Pool, IAaveOracle
  src/XLayerAddresses.sol        verified addresses + constants
  test/unit/                     lifecycle, registry, venue, vault, resolver
  test/invariant/                two solvency suites
  test/separation/               §4.7 model-and-money separation
  test/fork/                     against live X Layer mainnet
  script/VerifyIntegration.s.sol passing against live mainnet
```

**Not written yet:** the pricing agent, the benchmark corpus, and the frontend.
Mainnet is not deployed. X account not created.

### How the contracts fit together

```
user deposits -> xCoverVault
                   |-- venue.deposit()          assets supplied to Aave (or custodied on testnet)
                   |-- registry.consumeQuote()  reverts if declined / stale / mispriced
                   |-- policy.mintPolicy()      -> pool.reserveCover()  reverts if unbacked
                   \-- _mint(shares)

keeper/anyone -> resolver.recordObservation()   one per block, reads Aave live
anyone        -> resolver.evaluate(id, terms)   all samples in window must hold
                   \-- policy.markClaimable()
anyone        -> resolver.claim(id)
                   |-- policy.markPaid()
                   \-- pool.payClaim()          pays the current policy holder
```

Role wiring at deployment (get this right or nothing works):

| Contract | Role | Holder |
|---|---|---|
| `CoverPool` | `VAULT_ROLE` | `CoverPolicy` |
| `CoverPool` | `CLAIM_ROLE` | `ClaimResolver` |
| `CoverPool` | `ADMIN_ROLE` | deployer/admin |
| `CoverPolicy` | `VAULT_ROLE` | `xCoverVault` |
| `CoverPolicy` | `CLAIM_ROLE` | `ClaimResolver` |
| `PricingRegistry` | `PRICER_ROLE` | the agent's signing key |
| `PricingRegistry` | `VAULT_ROLE` | `xCoverVault` |
| venue | `VAULT_ROLE` | `xCoverVault` |

`xCoverVault.setTermsHash()` must be called before the first deposit, and the
`Terms` struct it hashes must be the same one `ClaimResolver.evaluate` is later
given — the resolver rejects any mismatch on the hash.

**All of this wiring is now executed by `script/Deploy.s.sol`**, which both
networks share, so neither can be wired differently by accident. The table above
is what it does; do not hand-wire a deployment. `DeployTestnet.s.sol` and
`DeployMainnet.s.sol` supply only the asset, the venue, and the parameter set.
`TestnetVenue` also grants `DEMO_ROLE` to the deployer, which is what lets a judge
induce a deficit; there is no equivalent on mainnet.

### Design decisions already made, with reasons

Do not silently reverse these; they were argued for and are load-bearing.

- **`_reserve` is the only function that can raise `outstandingCover`.** The
  solvency check lives inside it, so no later code path can bypass it.
- **`capital` is credited from the amount actually received**, not the amount
  requested, so a fee-on-transfer asset or a stray donation cannot inflate
  underwriting headroom.
- **Recording observations and settling claims are both permissionless.** A
  keeper who could withhold either could deny a valid claim without ever calling
  a function named "deny".
- **A depeg pays the shortfall against peg, not full cover.** The depositor still
  holds an asset worth something.
- **`AaveV3Venue` approves Aave for exactly one supply and zeroes it after.** Aave
  is an upgradeable proxy; a standing unlimited allowance is avoidable risk.
- **`CoverPool` contains no `approve` call at all**, which is how the reflexivity
  rule is enforced. There is a bytecode test asserting the selector is absent.
- **`ClaimResolver` reads its triggers through `IYieldVenue`, not `IAaveV3Pool`.**
  It was originally bound to Aave directly, which made every trigger unreadable on
  testnet — where Aave does not exist — and therefore made the judge-triggerable
  claim impossible. `observeReserve` returns the deficit, the price and the
  redeemable liquidity as one reading, because the resolver samples them as one
  block's worth of state; three separate calls would let a caller pair a deficit
  from one block with a price from another and call it an observation.
- **`TestnetVenue.induceDeficit` moves real tokens out of the venue** rather than
  incrementing a counter, and deliberately does not reduce `deposited`. That gap
  between what is owed and what is held is what a deficit *is*, and it is how Aave
  models it too. A counter would mean the payout a judge watches settles against
  an imaginary loss.
- **Plain ERC-4626 `deposit`/`mint` revert.** They cannot carry a quote, so they
  cannot mint cover, and an uncovered deposit is the worst possible outcome.

---

## 5. Traps already hit, so nobody pays for them twice

These cost real debugging time in this repository. They are not hypothetical.

**`vm.expectRevert` and `vm.prank` are consumed by the *next call*, including a
call in an argument list.** All of these are broken:

```solidity
vm.prank(alice); pool.withdraw(pool.sharesOf(alice));   // sharesOf eats the prank
vm.expectRevert(...); foo(this.helperThatCallsOut());   // helper eats the expectRevert
```

Hoist the inner read into a local first. This bit three separate times here.

**An invariant suite can pass while proving nothing.** The first system invariant
run reported green with `policies minted: 0` — the daily cap had been consumed
once and never reset, so every later mint reverted and the invariants checked an
empty book. Every invariant suite therefore has an `invariant_CallSummary` that
logs how much real work the fuzzer did. Read it (`forge test --match-test
invariant_CallSummary -vv`) before believing a green run.

**Reverts roll back handler call counters**, so a counter reading zero means "never
succeeded", not "never attempted". Early `return`s do *not* roll back, so put the
counter increment after the early returns or it overstates activity.

**The resolver now enforces keeper cadence, not just sample count.** Found during
the live testnet payout: observations spaced ~28 blocks apart put only about five
inside a 120-block window. The corrected terms require samples to span the window,
keep every unseen gap within the configured maximum, and keep the newest sample
fresh. Testnet uses a 30-block maximum gap; mainnet uses 60 blocks and should target
noticeably more often. Size the keeper cadence against the window, not against the
RPC limit.

**Writing to a proxy's storage will brick it.** The first slot any call on the
Aave Pool reads is the ERC-1967 implementation pointer. The fork test's slot
search must skip it, and must probe with a low-level `staticcall` so a bad guess
cannot abort the search before the original value is restored.

**A mutation check expires when the code around it changes.** The window-sampling
tests dipped the deficit to zero for one block and asserted no payout. That was
mutation-checked when written and genuinely proved the window rule — until the
deficit payout became pro-rata. A zero-deficit sample makes the smallest share in
the window zero, so the payout rounds to nothing and the zero-payout guard
rejects the claim by itself; the entire sampling rule could then be deleted with
both tests still green. Nothing failed, so nothing drew attention to it. When a
test's subject changes, re-run its mutation rather than trusting the note that
says it was checked once. Fixed by making the dip sub-floor but non-zero, so the
rejection has to come from the rule the test names.

**An invariant cannot see a bug that is not a violation of it.** `payClaim`'s cap
on the payout had no test at all: `CoverPool` was covered only by the invariant
suites, and the handler bounded the payout to `reserved + 1`, so the fuzzer could
overpay by at most one wei — invisible against capital in the millions. Deleting
the cap left every invariant green. Widening the bound does not fix it either,
because over-paying is not insolvency: `payClaim` drops `outstandingCover`
alongside `capital` and `reserveCover` is gated on free capital, so the book stays
covered. It is theft from the providers, and no solvency property can express that.
A guard that rejects a specific input needs a test that supplies that input —
`test/unit/CoverPool.t.sol`. Invariants and unit tests are not substitutes.

**Mutation-check every test that asserts an absence.** Break the thing on purpose,
confirm the test fails, restore. Done for both solvency invariants, the resolver's
window sampling, and the bytecode scans. A test that has never been seen to fail
is not evidence.

---

## 6. What is left, in order

The code correctness blockers found in review are now resolved in the working
tree. The remaining work is integration, evidence, and the required deployment
sequence. Do not use the historical testnet addresses for the competition demo;
the corrected source changes the terms hash and transfer behaviour.

### 6.1 Corrected testnet deployment and lifecycle — complete

The corrected set was broadcast on 18 August 2026 at block **38581492**. The
record in `deployments/xlayer-testnet.json` now carries all seven creation
transaction hashes, the explorer links, and terms hash
`0x3011f484e44ffe494015493b9f6ddbc04e526de0fc9f3b86ae99d65d9e47475f`.

The live lifecycle then completed against those addresses: policy #1 opened with
100,000 tUSDT capital and 10,000 tUSDT cover, a signed refusal was recorded, the
venue wrote off 2,500 tUSDT, five observations were mined at 20-block gaps, and
evaluation selected trigger **1 = ReserveDeficit** with a 2,500 tUSDT payout.
Settlement paid the holder, leaving pool capital at 97,500 tUSDT and outstanding
cover at zero. Direct post-settlement reads confirmed policy state `Paid` (4),
venue balance 7,500 tUSDT against 10,000 tUSDT deposited, and the 2,500 tUSDT
deficit.

The first lifecycle attempts exposed the public RPC latency problem and were not
used as evidence: their observation gaps exceeded 30 blocks. The final run used
raw signed transactions through the official `/terigon` testnet endpoint and
verified every receipt and block gap directly.

### 6.2 Submission blockers after testnet

**Pricing agent — not written.** Build the read → retrieve → assess → compute →
gate pipeline from SPEC §5. It must produce EIP-712 `Decision` signatures for
`PricingRegistry`, serve canonical decision JSON at `GET /decision/:hash`, and
treat `DECLINE_TO_QUOTE` as a first-class result. The signing key needs no gas.
Done means one agent-signed quote is consumed by a real testnet deposit and one
agent-signed refusal is rejected on the same path.

**Benchmark corpus — not started.** Complete the corpus behind
`bench/threshold-derivation.md`. The 50 bp deficit floor and $0.97 depeg bound
are documented; the rest of the deployment parameters remain reasoned defaults
and must be reviewed before mainnet.

**Mainnet deployment — not done.** First rerun `VerifyIntegration.s.sol` against
chain 196, fund the deployer with the minimum real capital and gas, then run
`DeployMainnet.s.sol` only after the corrected testnet record exists. Verify the
new mainnet deployment directly and commit its record. The deployer mainnet
balance was previously zero.

**Presentation layer — not started.** Frontend, benchmark figures, demo video,
X account and the first build post remain after the chain evidence is complete.

### 6.3 Testing debt worth knowing about

Two lessons from 17 August, both in §5 in full, both of which produced tests that
passed while proving nothing:

- A mutation check **expires** when the code around it changes. Re-run it when a
  test's subject moves; do not trust a note saying it was checked once.
- An invariant cannot see a bug that is not a violation of it. `payClaim`'s
  payout cap had no test at all because it was assumed covered by the solvency
  suites, which cannot express it — over-paying is theft, not insolvency.

The older absence-asserting tests were re-checked by mutation on 17 August. The
new ownership and sampling tests added in the current session pass normally but
have not yet had an independent mutation run.

### Definition-of-done items already satisfied

- Solvency invariant across fuzzed call sequences — two suites, mutation-checked
- `test_PricerCannotMovePoolFunds`, `test_PricerCannotAlterClaimOutcome`,
  `test_AdminCannotDenyValidClaim` — all passing
- `CoverPool` capital never supplied to a covered reserve — bytecode-asserted
- Pause blocks issuance but never claims or withdrawals
- `AaveV3Venue` exposes no deficit-writing surface
- `test/fork/ClaimPayout.t.sol` passing against forked mainnet
- Reserve deficit judged as a share of the reserve, paid pro-rata above a 50 bp
  floor — twelve tests, two against the live Aave Pool, all mutation-checked
- `CoverPool`'s own guards asserted directly in `test/unit/CoverPool.t.sol`
- Oracle wiring and immutable-aToken observation source verified on a live fork
- Policy and vault-share transfer desynchronization closed by rejecting direct transfers
- Observation span, freshness and maximum-gap checks covered by unit and live-fork tests
- Zero-capital provider-share epoch regression covered directly

Still open from §11: config loader environment pairing (belongs with the agent),
mainnet deployment, real capital, agent, benchmark, frontend, X account.

### Deployed, and the keys behind it

**X Layer testnet (1952) has the corrected deployment** at block 38581492. Use
the addresses and transaction hashes in `deployments/xlayer-testnet.json` for
competition evidence; the older deployment at block 38540175 remains historical
only. Its terms hash is `0x3011f484e44ffe494015493b9f6ddbc04e526de0fc9f3b86ae99d65d9e47475f`.
Mainnet is not deployed.
`DeployMainnet.s.sol` refuses to run without a testnet record, but the record must
be the corrected redeployment, not merely the historical file.

| Key | Address | Holds |
|---|---|---|
| Deployer / admin | `0xF3c2991BCa976c9ecC55c1C1eb8e2fD6E21baae8` | `ADMIN_ROLE` (pause issuance only), `DEMO_ROLE` on `TestnetVenue` |
| Pricer | `0x48E94cd8f946cb10b79Ad27cEE38037c9b3eE909` | `PRICER_ROLE` — signs quotes and refusals, nothing else |

The pricer key was regenerated on 17 Aug 2026 during the testnet redeployment: the
original (`0x45cF11D5…`) lived only in a `.env` that did not survive to the next
machine. Nothing is lost by regenerating — the key signs quotes and holds no other
role — but **`.env` is the only copy and it is gitignored.** If it is lost again,
the pricer changes again and `PRICER_ROLE` must be regranted.

Both private keys live in `.env` and nowhere else. The deployer key is funded on
testnet only; its mainnet balance is zero and mainnet funding is still owed.

**A note that cost time once:** `.env` must contain `NAME=value` lines. A private
key pasted in bare, with no `DEPLOYER_PRIVATE_KEY=` in front of it, leaves
`vm.envUint` unable to see it and every script failing on a missing env var rather
than on anything to do with the key. Copy `.env.example` and fill it in.

---

## 7. Open questions for the owner

- **Mainnet capital: owner will fund; amounts can be small.** Cover written can
  never exceed capital supplied, so a small book is the same product with a
  smaller book. Working minimum: ~100 USDT pool capital, ~50 USDT covered deposit
  (same wallet is fine), plus OKB for gas. Needed at deployment, not before. The
  README must state the book size plainly rather than implying scale.
- ~~Testnet OKB for the deployer.~~ **Done.** Funded 17 Aug 2026 with 0.2 OKB,
  which turned out to be ~400x what was needed: the full testnet deployment cost
  **0.000196 OKB** and the whole lifecycle run a fraction more. The faucet worry
  was unfounded — one day's 0.01 OKB would have covered it comfortably.
- ~~A dedicated `PRICER_PRIVATE_KEY`.~~ **Done.** Generated 17 Aug 2026, in `.env`
  only, never committed. It signs quotes and refusals and holds no other role; the
  deploy scripts refuse to run if it equals the deployer key.
- `ANTHROPIC_API_KEY` for the pricing agent. Still needed.
- Mainnet deployer funding and gas. Still needed before chain 196 deployment.

---

## 8. Schedule and what never gets cut

Submission target **20 August 2026**. Deadline is 21 August 23:59 UTC. Submit on
the 20th, never on deadline day.

Schedule is planning context only — it must never leak into commit messages.

**Contingency order if forced:** reduce benchmark size (never drop it), then
simplify the capital-provider UI, then reduce keeper frequency.

**Never reduce:** the solvency invariant test, the fork payout test, the three
separation tests, the refusal path, the testnet→mainnet sequence.

---

## 9. Honest limitations to state, not hide

Carry these into the README rather than letting a reviewer find them:

- No loss history exists for this market, so the pricing model is extrapolating
  from protocol-risk priors rather than fitted to realised claims. Say so.
- The testnet deployment has no live Aave behind it, because Aave is not on X
  Layer testnet. Say which venue backs which deployment.
- Covering one reserve on one protocol is a small correlation surface by design,
  not by accident. The wrapped reserves carry an extra bridge failure mode and
  are deliberately out of scope.
