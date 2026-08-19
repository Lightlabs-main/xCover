# xCover — Session Handoff

Everything needed to resume work on xCover from a cold start, on any machine,
with no memory of previous sessions. Self-contained on purpose: paste this to a
fresh agent, or point one at this file in the repo.

**A Claude Code session loads `CLAUDE.md` automatically**, and that file points
here — so on a new codespace you do not need to explain any of this. Just say
what you want built. Read `CLAUDE.md` first if you are a human picking this up
cold; it is the short version of this document.

Repo: `https://github.com/Lightlabs-main/xCover`
Last updated: 18 August 2026 — 139 contract tests and 11 agent tests passing; corrected source deployed and lifecycle-proven on X Layer testnet at block 38581492; mainnet not deployed

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

Remaining: review the operator-selected runtime parameters, fund and deploy
mainnet, and finish the submission presentation. The pricing agent and corpus
exist; the corpus produced no usable confidence calibration, so no calibrated
quote is claimed.

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

The pricing-agent scaffold is written and unit-tested; the benchmark corpus and
frontend are not written yet. Mainnet is not deployed. X account not created.

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

## 4a. Picking this up cold — the pricing agent, as of 18 August 2026

Read this before touching `packages/agent` or `bench`. It is the state a previous
session left, written so the next one does not repeat paid mistakes.

### What is done and working

- `packages/agent` implements the full §5.2 pipeline and has its unit tests passing.
  It supports explicit Anthropic and Gemini providers through their official SDKs;
  the Anthropic path has been proven end to end against the live API. Gemini has now
  completed a one-row live smoke against `gemini-3.5-flash-lite`; calibration stopped
  at the control gates and no threshold is claimed.
- `bench/data/corpus.jsonl` — **229 labelled scenarios, every citation fetched and
  checked.** 148 incidents cited to `rekt.news`, 81 judged-valid Code4rena findings.
  Build scripts in `bench/tools/` reproduce it. This artifact is sound.
- `packages/agent/bench/score.mts` — the scoring harness. Leave-*protocol*-out retrieval,
  anonymised scenarios, two framings, resumable, prints actual spend.

### What is blocked, and why more spending will not unblock it

The §5.4 calibration **cannot be produced from this corpus**, and this is proven, not
suspected. The corpus's two halves come from different source types written in different
vocabulary, so retrieval returns a same-class neighbourhood 99.8% of the time and the
model reads the answer off its neighbours' `outcome` fields. Full evidence in
`bench/README.md` § "Result: this corpus cannot support the §5.4 calibration".

**Do not re-run the scoring hoping for a different number.** The fix is new negative
scenarios drawn from the same source and vocabulary as the positives — protocols with a
comparable profile that were not exploited, described in the same terms. That is a
sourcing problem, not a code or budget problem.

### If you continue, the cheap order

1. **Free first.** Any new corpus design should be checked with the two free diagnostics
   before a single paid call: what fraction of retrieved neighbours share the scenario's
   label, and does any presented field separate the classes perfectly (chain and target
   type both did, and had to be withheld).
2. **$0.25 next.** Run the control — scenarios with retrieval disabled. If accuracy is
   meaningfully above chance, stop; the framing still leaks.
3. **$6.80 last.** Only then score the full corpus, and only against the model you intend
   to deploy.

### Gemini calibration continuation — start here next session

The Gemini adapter is now implemented in `packages/agent/src/gemini.ts`, selected by
`PRICING_MODEL_PROVIDER=gemini`, and covered by the agent build and tests. It is the
provider path to use for a Gemini calibration. It does **not** make the old corpus valid:
the old 229 rows still mix incident write-ups with Code4rena audit findings, so the
confidence signal learned the source vocabulary rather than risk.

Do this in order, and stop at the stated gates:

1. **Resume without exposing secrets.** From the workspace root, source `.env` without
   printing it. Confirm only that `PRICING_MODEL_PROVIDER=gemini`, `GEMINI_API_KEY`, and
   `GEMINI_MODEL` are set. Do not add `PRICING_CONFIDENCE_THRESHOLD_BPS` yet; the scorer
   does not need it, and no value has been measured.

2. **Build a new corpus, not a rerun.** Create a separate artifact such as
   `bench/data/corpus-gemini.jsonl` with 150–250 labelled scenarios. Both labels must be
   drawn from the same source family and written in the same vocabulary: comparable
   protocol-risk situations with known loss and known no-loss outcomes. Do not use the
   existing Code4rena-audit side as the negative class for `rekt.news` incidents. Fetch
   and check every citation, hold out the entire protocol under test, and keep `label`,
   `outcome`, `lossUsd`, protocol names, and any direct outcome markers out of the model
   situation/evidence text. The current scorer's retrieved payload still contains
   `protocol` and `outcome`, so sanitize that model-facing payload as part of this
   rebuild; internal scoring may retain the labels separately.

3. **Add a corpus-path argument before scoring.** `packages/agent/bench/score.mts` currently
   defaults to `bench/data/corpus.jsonl`. Add an explicit `--corpus=<path>` option and
   preserve the old artifact unchanged. The output must retain `provider`, `model`, token
   usage, both framings, and the exact corpus path so the run is reproducible. The
   model-facing evidence must omit `label`, `outcome`, `lossUsd`, protocol identity, and
   any equivalent source-family marker; otherwise the new run repeats the old leak.

4. **Run free leakage checks.** Before calling Gemini, verify the new corpus schema and
   citations, class balance, protocol overlap, and retrieval label purity. Reject the
   corpus if a field (chain, target type, source family, wording, or outcome phrase)
   separates the labels, or if retrieved neighbours overwhelmingly share the answer.
   These checks are local and must produce a short report committed beside the corpus.

5. **Run one Gemini smoke scenario only.** Use the new corpus path, `--limit=1`, and
   `--concurrency=1`. Inspect that the response is structured JSON, uses decimal strings,
   cites only permitted ids, records token usage, and produces two passes. If it fails,
   fix the adapter or prompt before increasing the limit. Do not launch a full run while
   the smoke result is malformed.

6. **Run the no-evidence control.** Score a small balanced sample with retrieval disabled.
   If performance is materially above chance, stop: the scenario framing still leaks the
   label. If it passes, run the same small sample with retrieval and check that retrieval
   improves judgement without label-pure neighbours. Record the token counts; the Gemini
   harness reports usage but does not estimate provider pricing.

7. **Score the full new corpus only after the gates pass.** Use the exact Gemini model and
   the same confidence semantics, prompt version, schema, and settings intended for the
   deployed agent; record any unavoidable benchmark/runtime difference. Resume from the
   output file if a quota or network error occurs; never treat an error row as a score.
   Save the raw JSONL and the run metadata. Do not mix Gemini rows with the old Anthropic
   scores.

8. **Derive the threshold from the Gemini run.** Bin `confidenceBps`, compare stated
   confidence with observed correctness, verify monotonicity, measure the overconfidence
   offset, then select the operating point using the cost asymmetry from SPEC §5.4. Write
   the calculation in `bench/threshold-derivation.md`. Only after this produces a
   defensible operating point may `PRICING_CONFIDENCE_THRESHOLD_BPS` be filled in.

9. **If calibration fails again, stop honestly.** Leave the threshold unclaimed and record
   the failure. Do not spend another full run on the same corpus expecting tuning to fix a
   source or label leak. A Gemini result that fails the same diagnostics is evidence that
   the corpus is still unsuitable, not evidence that more credits will solve it.

### Gemini attempt on 19 August 2026 — stopped at controls

The new Code4rena-only candidate is now materialised as `bench/data/corpus-gemini.jsonl`
with 177 rows across 14 protocol groups. `bench/data/gemini-corpus-check.md` passes the
offline source-family, prompt-leakage, whole-protocol holdout and retrieval-purity gates
(53.2% weighted purity against a 75% stop threshold). The loss label is explicitly
protocol-level and does not claim that each individual finding caused an incident.

One live smoke succeeded against `gemini-3.5-flash-lite`. The first 152-row candidate's
partial no-evidence control was rejected after AUC 0.81 on 12 completed rows, with the
remaining requests stopped by the free-tier quota. Adding Sturdy V1 and Tapioca DAO
findings produced a six-row balanced control with AUC 0.33; the same six rows with
evidence produced AUC 0.17. Those samples are too small to certify a calibration curve,
and retrieval did not improve the signal, so no evidence run or full 177-row run was
started. Full details are in `bench/data/gemini-calibration-status.md`.

### Budget reality

$9.00 was spent reaching the conclusion above. Roughly $4 of that was avoidable: a full
scored run was launched on a cost projected from a no-evidence control, which understated
it by more than half. The measured per-scenario rates are in `bench/README.md` and the
harness now prints real spend after every run.

### The honest position for the README and the submission

The agent is implemented, unit-tested, and proven to make real cited assessments against
the live API. Its confidence signal was measured against a 229-scenario cited corpus and
**failed calibration**, and the benchmark's own weaknesses were then measured and
published rather than hidden. That is a stronger and more defensible claim than an
unexamined accuracy figure would have been — but it does mean **no live quote has been
issued**, and the README must say so plainly.

## 5. Traps already hit, so nobody pays for them twice

These cost real debugging time in this repository. They are not hypothetical.

**`vm.expectRevert` and `vm.prank` are consumed by the *next call*, including a
call in an argument list.** All of these are broken:

```solidity
vm.prank(alice); pool.withdraw(pool.sharesOf(alice));   // sharesOf eats the prank
vm.expectRevert(...); foo(this.helperThatCallsOut());   // helper eats the expectRevert
```

Hoist the inner read into a local first. This bit three separate times here.

**A configured model id is not a working model id.** `.env` carried
`claude-3-5-sonnet-20241022` and the docs recorded it as the current
configuration, but the key returns HTTP 404 for it. Nothing failed loudly: the
agent catches an assessment failure and refuses, so the only symptom was a
refusal that looked principled. A refusal whose real cause is configuration is
worse than a crash, because refusal is a correct outcome here and hides the
fault. Check `GET /v1/models` before recording a model as configured, and run
one assessment end to end.

**The current models reject `temperature`.** The hand-rolled request body sent
`temperature: 0` for determinism, which now returns
`400 invalid_request_error`. Determinism in this system comes from the
deterministic computation and the gate, plus committing the model output to the
replayable decision document — never from sampling parameters. The call now
goes through the official SDK so the request shape is not maintained by hand.

**A citation validator can reject a correct assessment.** The prompt demanded an
evidence id on every hazard factor, but several sound factors come from the live
chain read, which had no id. The live model cited `live-chain-state` unprompted,
the validator rejected the whole assessment, and the decision refused with
`model_assessment_failed`. That id is now reserved and documented in the prompt;
the corpus may not claim it.

**A benchmark can score 100% and measure nothing.** Three separate times on this
corpus, high accuracy turned out to be an artifact. Named protocols let the model
recall the outcome (17/20 with no evidence at all). Anonymising fixed that (12/20,
chance being 10/20) — and then retrieval leaked the label instead, because 99.8% of
retrieved neighbours share the scenario's own label and every corpus row states its
outcome in words. Before trusting any accuracy figure from a retrieval benchmark, run
it with retrieval disabled, and check what fraction of the retrieved neighbourhood
shares the answer. Both checks are cheap; the second is free.

**Do not project one run's API cost from a different run's.** A no-evidence control has
prompts about 6.5x smaller than a real scored run. Projecting the full run from the
control understated it by more than half and overspent the budget by $4. Measured rates
are in `bench/README.md`; `bench/score.mts` now prints actual spend and refuses to
project across run types.

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

**Pricing agent — implemented and live-path proven.** `packages/agent` now
implements the read → retrieve → assess → compute → gate pipeline from SPEC §5.
It produces EIP-712 `Decision` signatures for `PricingRegistry`, stores and
serves canonical decision JSON at `GET /decision/:hash`, and treats
`DECLINE_TO_QUOTE` as a first-class signed result. The signing key needs no gas.
The API key and `ANTHROPIC_MODEL=claude-opus-5` are present in `.env`, and the
assessment call has been exercised end to end against the live API: it returns a
parsed, bounded, cited assessment. The previously configured
`claude-3-5-sonnet-20241022` did not exist for this key and returned HTTP 404,
so every live decision would have refused with `model_assessment_failed` — a
refusal caused by configuration rather than by insufficient evidence. Verify a
model id against `GET /v1/models` before recording it as configured.

**The confidence threshold is not derived and cannot be derived from the current
corpus.** The benchmark exists (229 cited rows) and was scored in full, but every
route to high accuracy on it proved to be an artifact — see
`bench/threshold-derivation.md` and `bench/README.md`. `PRICING_CONFIDENCE_THRESHOLD_BPS`
therefore has no measured value, and no quote is claimed. Disagreement and
uncertainty bounds *were* measured and are usable if described honestly.

Note a live discrepancy: `.env` names `claude-opus-5`, but the benchmark runs were
made against `claude-sonnet-5` at `effort: low` for cost. A calibration measures one
configuration, so **whichever model is deployed is the one that must be scored** — the
existing scores do not calibrate an Opus 5 deployment. The 50 bp deficit floor and
`97_000_000` depeg bound are spec-defined; the confidence, disagreement,
uncertainty, oracle, capital-margin, premium-ceiling, and quote-TTL values are
runtime/review parameters, not hidden spec defaults. The full provenance table
is in `docs/pricing-agent.md`. Done still means one agent-signed quote is
consumed by a real testnet deposit and one agent-signed refusal is rejected on
the same path. The current corrected testnet venue has a non-zero residual
deficit after the proven payout, so its live gate correctly refuses until a clean
eligible venue state is available.

**Benchmark corpus — assembled and scored, with a negative calibration result.**
`bench/data/corpus.jsonl` contains 229 cited labelled scenarios and every citation
was fetched and checked. The confidence signal is not monotonic and the corpus's
accuracy is an information-leakage artifact; `bench/threshold-derivation.md`
records the evidence. Do not invent `PRICING_CONFIDENCE_THRESHOLD_BPS` or rerun
the same scoring. A new corpus needs same-source, same-vocabulary negatives.

**Mainnet deployment — not done.** First rerun `VerifyIntegration.s.sol` against
chain 196, fund the deployer with the minimum real capital and gas, then run
`DeployMainnet.s.sol` only after the corrected testnet record exists. Verify the
new mainnet deployment directly and commit its record. The deployer mainnet
balance was previously zero.

**Presentation layer — not started.** The next safe implementation slice is a
dependency-free read-only dashboard in `apps/web` that reads live RPC state for
the corrected testnet deployment and shows mainnet as explicitly not deployed.
It must not submit transactions, use mocks, or imply that the testnet's residual
deficit is eligible for quoting. Demo video, X account and the first build post
remain external submission work.

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

Still open from §11: reviewed operator runtime parameters, mainnet deployment,
real capital, and external submission work (demo video, X account, first build
post). The config loader, pricing agent, corpus, and read-only presentation are
implemented.

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
- `ANTHROPIC_API_KEY` is present in the local `.env`. Never print or commit it.
  The current key's read-only model list includes `claude-opus-5` and
  `claude-sonnet-5`, but not the previously requested Claude 3.5 id. The local
  `.env` currently names `claude-opus-5`; the existing benchmark used
  `claude-sonnet-5` at low effort and therefore calibrates neither model as a
  deployment threshold.
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
