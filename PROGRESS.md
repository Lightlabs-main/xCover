# xCover — Progress & Handoff

**Single source of truth for scope:** `docs/SPEC.md`. Read §1 before every
session. If this file and the spec disagree, the spec wins and this file is
stale — fix it.

**Starting cold?** `CLAUDE.md` is the entry point and loads automatically in a
Claude Code session; `HANDOFF.md` has the full cold-start detail. This file
carries only current state and what happens next.

**Submission:** X Layer AI Season. Target **20 August 2026**; deadline 21 August
23:59 UTC. Today: 17 August 2026.

---

## Current state

| Area | State |
|---|---|
| `docs/SPEC.md` | Complete — §1–12, treated as binding |
| Git repository | `Lightlabs-main/xCover`, `main` pushed. Commits authored `Lightlabs-main <lightlabs112@gmail.com>` |
| Monorepo scaffold | pnpm workspace + Foundry project building |
| Chain verification (§3.3) | **Done, all five calls, recorded in `docs/chain-verification.md`** |
| Testnet probe (§3.5) | **Done — Aave absent from testnet, `TestnetVenue` required** |
| `VerifyIntegration.s.sol` (§3.6) | **Written and passing against live mainnet** |
| Solvency invariant (§1.2.4) | **Written and passing** — `test/invariant/CoverPoolSolvency.t.sol`, three properties, 16,384 calls per run. Mutation-checked: removing the check in `_reserve` fails it. |
| System invariant | **Written and passing** — `test/invariant/CoverSystemSolvency.t.sol` drives the pool through `CoverPolicy`, the real issuance path, and adds: a policy holds a reservation iff it is Active or Claimable. Mutation-checked. |
| Contracts | All five: `CoverPool`, `CoverPolicy`, `xCoverVault`, `ClaimResolver`, `PricingRegistry`, plus `IYieldVenue` + `TestnetVenue` + `AaveV3Venue`. **127 tests passing** — 118 off-fork, 9 against live X Layer mainnet. |
| `xCoverVault` | **Written and passing.** One transaction: supply → consume quote → mint policy → mint shares. Plain ERC-4626 `deposit`/`mint` revert by name rather than producing an uncovered position. Refusal, staleness, capacity and terms-mismatch each refuse the deposit with the user's assets untouched. |
| `ClaimResolver` | **Written and passing.** All three triggers with windowed sampling; permissionless observation and settlement; no admin override in either direction. Mutation-checked: making one sample sufficient fails the window test. |
| Separation tests (§4.7) | **All five written and passing** — `test/separation/ModelMoneySeparation.t.sol` |
| Fork payout test (§6.1) | **Passing.** `test/fork/ClaimPayout.t.sol` runs deposit → cover → trigger → settlement against the live Aave Pool, paying 50,000 USDT to the holder. The deficit is planted in the live Pool's storage (slot discovered at runtime, not hardcoded) because the real reserve is healthy; everything reacting to it is real Aave bytecode. Also asserts a transient deficit does not pay, and that the claim touches neither the position nor Aave's deficit. |
| `AaveV3Venue` against real Aave | **Passing on a forked X Layer mainnet.** Supplies real USDT, receives real aUSDT, accrues real interest (11.977953 USDT on 50,000 over 30 days), redeems in full. First product contract to run against a real dependency. |
| Deployment scripts | **Written.** `Deploy.s.sol` holds the wiring both networks share; `DeployTestnet` / `DeployMainnet` supply only asset, venue and parameters. Mainnet refuses to run without the testnet record. A simulation deliberately does not write the deployment record — only a real broadcast does. |
| **X Layer testnet (1952)** | **Deployed 17 Aug 2026, block 38522841 — now SUPERSEDED, redeployment required.** The deployed contracts carry the pre-fix deficit trigger; `termsHash` has since changed and cannot be upgraded into. |
| ~~X Layer testnet, original~~ | Original record: All seven contracts, roles verified on chain, `deployments/xlayer-testnet.json` committed with tx hashes and explorer links. Cost 0.000196 OKB. |
| **Live testnet lifecycle** | **Full path ran on chain 17 Aug 2026:** capital → signed quote → covered deposit (policy #1) → recorded refusal → real deficit induced → 9 windowed observations → `ReserveDeficit` trigger → **10,000 tUSDT paid to the holder**. Verified by reading the chain, not the script log. |
| X Layer mainnet (196) | Not deployed. Deployer balance is zero there; funding still owed. |
| Deficit trigger | **Fixed and tested; not yet redeployed.** Pays pro-rata above a 50 bp floor. Ten unit tests and two fork tests now cover the dust rejection, both sides of the floor, the pro-rata payout, the smallest-share-in-window rule, the empty reserve, the rounds-to-zero case, and all three trigger-precedence cases — all mutation-checked against the original bug. **The fork suite has been re-run against live X Layer mainnet and passes:** 499 bp of the live reserve pays 2,495 USDT on 50,000 of cover. |
| Threshold derivation | **Started.** `bench/threshold-derivation.md` records the 50 bp deficit floor and the $0.97 depeg bound with their measurements, and names the parameters that are still reasoned defaults. |
| Pricing agent | None written |
| Benchmark corpus | Not started |
| Frontend | Not started |
| X account | Not created |

The day-one verification has been executed against live X Layer mainnet,
`AaveV3Venue` has run against the real Aave V3 Pool on a mainnet fork, and **the
full contract set is now deployed and running on X Layer testnet**, where the
covered-deposit path and the refusal path have both executed on chain. What is
still unproven end to end on a live network is the Aave integration itself, which
exists only on mainnet and is covered by the fork tests until the mainnet
deployment happens.

## Settled by chain verification

Full evidence in `docs/chain-verification.md`. The decisions these force:

- **`getReserveDeficit` exists and returns cleanly** (returns `0`, no revert;
  pool revision 11). The deficit trigger is buildable as specified. **The
  redemption-failure fallback is not needed as primary** — do not build toward
  it.
- **`POOL_IMPL` on chain matches the address book**, read from the ERC-1967 slot.
- **USDT reserve is active, unfrozen, 6 decimals, 50.2M supplied.** Real
  depositors; cover is written against something that exists.
- **Oracle live at $0.99896524.** Note the ~10 bp off-peg in normal conditions:
  the depeg threshold must sit well outside that or it fires on noise. Input to
  `bench/threshold-derivation.md`.
- **Aave is not on X Layer testnet** (`0x` code at `POOL` and
  `POOL_ADDRESSES_PROVIDER`). `IYieldVenue` + `TestnetVenue` is **required**,
  not optional.
- **Testnet chain id is 1952, not 195.** 195 is deprecated on ChainList. Use
  1952 everywhere — foundry config, frontend chain config, deployment records.
- RPC rate limit is **100 rps per IP** on both networks. This constrains keeper
  polling frequency (§5.5); design for it rather than discovering it in
  production.

---

## Immediate next actions

1. **Redeploy to X Layer testnet (1952).** The deployed set carries the pre-fix
   deficit trigger and `termsHash` has changed, so it cannot be upgraded into.
   The code side is now ready — tests and fork suite both green. **Blocked on
   `.env`:** this machine has no `DEPLOYER_PRIVATE_KEY` or `PRICER_PRIVATE_KEY`,
   which live only in `.env` on the machine that ran the first deployment. Copy
   `.env.example` and fill both in, then rerun `DeployTestnet.s.sol` and the
   lifecycle script, and replace `deployments/xlayer-testnet.json`.
2. The pricing agent: read, retrieve, assess, compute, gate — producing the
   signed decisions `PricingRegistry` already accepts.
3. Review the provisional deployment parameters before mainnet. The waiting
   period, sampling window, minimum samples and daily cap in `script/Deploy*.s.sol`
   are reasoned defaults, not derived ones, and are flagged as such in the code and
   in `docs/deployments.md`. Only `depegLowerBound` ($0.97) is grounded in evidence.
4. Start the benchmark corpus. Long-lead item: it gates the threshold, and the
   threshold gates the agent's `DECLINE_TO_QUOTE` behaviour.
   `bench/threshold-derivation.md` now exists and holds the two derived
   thresholds; the corpus itself is still to be built.
5. Create the X account and publish the first build post.

---

## Open questions for the owner

- **Mainnet capital: resolved in principle — owner will fund.** Amounts do not
  need to be large: cover written can never exceed capital supplied, so a small
  book is the same product with a smaller book, not a degraded one. Working
  minimum is ~100 USDT as pool capital, ~50 USDT as the covered deposit (same
  wallet is fine), plus OKB for gas. Needed at deployment, not before. The README
  must state the book size plainly rather than implying scale.
- Testnet OKB for the deployer: the OKX faucet gives 0.01 OKB/day, which may
  need starting now to cover the full testnet deployment set.

---

## Blocked

Nothing. The §3.3 and §3.5 unknowns that gated the contract work are resolved,
and the repository is live.

Note for pushing from this codespace: the ambient `GITHUB_TOKEN` is refused for
git pushes to xCover and takes precedence over the working credentials in
`~/.config/gh/hosts.yml`. Prefix git and gh commands with `GITHUB_TOKEN=`.

---

## Things that must not be cut

From §8 contingency order. If time is short, reduce the benchmark size (never
drop it), then the capital-provider UI, then keeper frequency. **Never reduce:**
the solvency invariant test, the fork payout test, the three separation tests,
the refusal path, the testnet→mainnet sequence.

---

## Session log

| Date | Session outcome |
|---|---|
| 16 Aug 2026 | Project renamed Ward → xCover. `docs/SPEC.md` drafted in full. |
| 17 Aug 2026 | Solvency invariant written before `CoverPool` and mutation-checked; `ICoverPool` + `CoverPool` implemented against it. `CoverPolicy` lifecycle built with 22 unit tests, and a second invariant added that drives the pool through the real issuance path. `PricingRegistry` added with signed quotes and recorded refusals; all five §4.7 separation tests written and passing. `IYieldVenue` with `TestnetVenue` and `AaveV3Venue`; the Aave venue passes against forked mainnet with real interest accrual. README written. |
| 17 Aug 2026 | Spec reviewed; handoff and memory index created. §3.3 verification and §3.5 testnet probe run against live chains and recorded. Monorepo + Foundry scaffolded; `VerifyIntegration.s.sol` written and passing against mainnet. First commit pushed to `Lightlabs-main/xCover`. |

| 17 Aug 2026 | Deployer key funded on testnet and a separate pricer key generated. Found and resolved a spec/code divergence: `ClaimResolver` was bound to `IAaveV3Pool`, which made every trigger unreadable on testnet — rebound to `IYieldVenue` via `observeReserve`. Added `TestnetUSDT` and `TestnetVenue.induceDeficit` so the testnet lifecycle is reachable at all. Wrote the deployment scripts, **deployed the full set to X Layer testnet (1952)**, and ran the whole path on chain including a 10,000 tUSDT claim paid to the holder. 116 tests passing. `docs/deployments.md` written. Total spend 0.000252 OKB. |

| 17 Aug 2026 | Closed the deficit-trigger gap. Ten unit tests and two fork tests written for the pro-rata payout and the 50 bp floor, each mutation-checked against the original bug. Re-ran the fork suite, which had not run since the change: two tests failed because the fixed 250,000 USDT it plants is 49.8 bp of the live reserve and now sits under the floor, and the transient-deficit test was passing for that reason rather than the one it names. Fork tests now size the deficit as a share of the live reserve. 127 tests passing. `bench/threshold-derivation.md` written. |

Update this table at the end of every session (§1.3).
