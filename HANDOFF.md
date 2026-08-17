# xCover — Session Handoff

Everything needed to resume work on xCover from a cold start, on any machine,
with no memory of previous sessions. Self-contained on purpose: paste this to a
fresh agent, or point one at this file in the repo.

Repo: `https://github.com/Lightlabs-main/xCover`
Last updated: 17 August 2026

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

Two commits on `main`:

- `150a1b7` — spec, chain verification, Foundry workspace, `VerifyIntegration.s.sol`
- `75fbc8c` — progress notes

```
docs/SPEC.md                     complete, binding, §1-12
docs/chain-verification.md       raw evidence, day-one verification
PROGRESS.md                      current state, next actions, session log
HANDOFF.md                       this file
package.json                     pnpm workspace root
pnpm-workspace.yaml
.env.example                     RPC endpoints, key placeholders
.gitignore
packages/contracts/
  foundry.toml                   solc 0.8.28, cancun, invariant profile
  remappings.txt
  package.json
  foundry.lock                   pins forge-std revision
  lib/forge-std                  submodule
  src/XLayerAddresses.sol        verified addresses + constants
  script/VerifyIntegration.s.sol passing against live mainnet
```

**Not written yet:** every product contract (`CoverPool`, `CoverPolicy`,
`xCoverVault`, `ClaimResolver`, `PricingRegistry`), the pricing agent, the
benchmark corpus, the frontend. No deployments. X account not created.

---

## 5. Next actions, in order

1. **Write the solvency invariant test before `CoverPool` exists.** The
   invariant defines the contract, not the reverse. Total claimable liability
   across active policies never exceeds pool capital, holding under fuzzed
   arbitrary sequences of deposits, mints, premium accrual, claims and
   withdrawals. This is the one test that must never be cut.
2. `CoverPool` + `CoverPolicy` written against that invariant. Then `IYieldVenue`
   + `TestnetVenue` — now known to be required.
3. Deploy the full set to X Layer testnet (chain 1952). Record addresses, tx
   hashes, block numbers and timestamps in `deployments/xlayer-testnet.json`.
   **Testnet must provably precede mainnet — this is an eligibility gate, not a
   preference.**
4. `xCoverVault` (ERC-4626) + `AaveV3Venue` against real Aave on a fork.
   `ClaimResolver` with all three triggers and block sampling.
5. Pricing agent: read, retrieve, assess, compute, gate. `PricingRegistry`,
   decision canonicalisation, hashing, public replay endpoint.
6. Benchmark corpus built and scored; calibration curve;
   `bench/threshold-derivation.md`. **Long-lead item — it gates the refusal
   threshold, which gates the agent.** Start it early.
7. Fork payout test, frontend, real capital on mainnet, README, demo video,
   submit.

### Required separation tests (§4.7)

- `test_PricerCannotAlterClaimOutcome`
- `test_AdminCannotDenyValidClaim`
- `CoverPool` capital is never supplied to a covered reserve
- Pause blocks issuance but never claims or withdrawals
- `AaveV3Venue` exposes no `induceDeficit` surface
- Config loader throws when chain environment and venue implementation disagree

---

## 6. Open questions for the owner

- Source of real capital for the mainnet pool and the live covered position.
  §11 requires both to be real.
- Testnet OKB for the deployer. The OKX faucet gives 0.01 OKB/day, so start
  collecting now if the full testnet deployment set needs more than a day's worth.
- `ANTHROPIC_API_KEY` and a dedicated `PRICER_PRIVATE_KEY` for signing quotes.
  That key must be able to produce prices and refusals only — never move money.

---

## 7. Schedule and what never gets cut

Submission target **20 August 2026**. Deadline is 21 August 23:59 UTC. Submit on
the 20th, never on deadline day.

Schedule is planning context only — it must never leak into commit messages.

**Contingency order if forced:** reduce benchmark size (never drop it), then
simplify the capital-provider UI, then reduce keeper frequency.

**Never reduce:** the solvency invariant test, the fork payout test, the three
separation tests, the refusal path, the testnet→mainnet sequence.

---

## 8. Honest limitations to state, not hide

Carry these into the README rather than letting a reviewer find them:

- No loss history exists for this market, so the pricing model is extrapolating
  from protocol-risk priors rather than fitted to realised claims. Say so.
- The testnet deployment has no live Aave behind it, because Aave is not on X
  Layer testnet. Say which venue backs which deployment.
- Covering one reserve on one protocol is a small correlation surface by design,
  not by accident. The wrapped reserves carry an extra bridge failure mode and
  are deliberately out of scope.
