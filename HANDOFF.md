# xCover — Session Handoff

Everything needed to resume work on xCover from a cold start, on any machine,
with no memory of previous sessions. Self-contained on purpose: paste this to a
fresh agent, or point one at this file in the repo.

**A Claude Code session loads `CLAUDE.md` automatically**, and that file points
here — so on a new codespace you do not need to explain any of this. Just say
what you want built. Read `CLAUDE.md` first if you are a human picking this up
cold; it is the short version of this document.

Repo: `https://github.com/Lightlabs-main/xCover`
Last updated: 17 August 2026 — all five §4 contracts written, 109 tests passing, nothing deployed

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
| `USDT_ORACLE` | `0x7ec7E5497EAf312FE82F8307D05eb0E5f0f157D3` |

Launch covers **USDT only** — deepest stable reserve, payout asset and covered
asset share a denomination so there is no FX exposure in the claim, and one
reserve keeps the correlation surface small enough to reason about honestly.

---

## 4. What exists right now

All five §4 contracts are written, with 109 tests passing. Nothing is deployed to
any network yet.

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

**Not written yet:** the pricing agent, the benchmark corpus,
the frontend. No deployments. X account not created.

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

**The keeper interval must divide the sampling window into comfortably more slices
than `minSamples`.** Found during the live testnet payout: observations spaced ~28
blocks apart put only about five inside a 120-block window, so the evaluation had to
be preceded by fresh observations or it would have reverted `InsufficientSamples` on
a completely valid claim. The failure mode is a valid claim that cannot be proven,
which is worse than it sounds — it looks like the resolver rejecting the claim.
Mainnet's 1,800-block window with `minSamples: 30` needs an observation at least
every 60 blocks and should target noticeably more often. Size the keeper cadence
against the window, not against the RPC limit.

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

## 6. Next actions, in order

1. **Deployment scripts, then deploy to X Layer testnet (chain 1952).** Wire the
   roles per the table above, using `TestnetVenue`. Record addresses, tx hashes,
   block numbers and timestamps in `deployments/xlayer-testnet.json`. **Testnet
   must provably precede mainnet — an eligibility gate, not a preference.**
   Needs testnet OKB: the OKX faucet gives 0.01 OKB/day, so start collecting
   before it is needed.
2. **The pricing agent.** `PricingRegistry` already accepts what it must produce:
   an EIP-712 `Decision` signed by a `PRICER_ROLE` key. Note the key never needs
   gas — decisions are signed off-chain and may be submitted by anyone. Serve the
   canonical decision JSON at `GET /decision/:hash` (RFC 8785) so the on-chain
   `decisionHash` is independently verifiable.
3. **Benchmark corpus and `bench/threshold-derivation.md`.** Long-lead: it gates
   the refusal threshold, which gates the agent. The oracle sits ~10 bp off peg
   in normal conditions, which is the first input.
4. **Frontend**, then mainnet deployment with real capital, README figures, demo
   video, submission.

### Definition-of-done items already satisfied

- Solvency invariant across fuzzed call sequences — two suites, mutation-checked
- `test_PricerCannotMovePoolFunds`, `test_PricerCannotAlterClaimOutcome`,
  `test_AdminCannotDenyValidClaim` — all passing
- `CoverPool` capital never supplied to a covered reserve — bytecode-asserted
- Pause blocks issuance but never claims or withdrawals
- `AaveV3Venue` exposes no deficit-writing surface
- `test/fork/ClaimPayout.t.sol` passing against forked mainnet

Still open from §11: config loader environment pairing (belongs with the agent),
mainnet deployment, real capital, agent, benchmark, frontend, X account.

### Deployed, and the keys behind it

**X Layer testnet (1952) is deployed** — addresses, tx hashes and explorer links in
`deployments/xlayer-testnet.json`, explained in `docs/deployments.md`. Mainnet is
not. `DeployMainnet.s.sol` refuses to run without the testnet record present, so
the eligibility order cannot be skipped by accident.

| Key | Address | Holds |
|---|---|---|
| Deployer / admin | `0xF3c2991BCa976c9ecC55c1C1eb8e2fD6E21baae8` | `ADMIN_ROLE` (pause issuance only), `DEMO_ROLE` on `TestnetVenue` |
| Pricer | `0x45cF11D571684174922a41c965263A03A0De5cd8` | `PRICER_ROLE` — signs quotes and refusals, nothing else |

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
