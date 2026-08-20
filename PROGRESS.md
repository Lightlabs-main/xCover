# xCover - Technical progress

**Single source of truth for scope:** `docs/SPEC.md`. Read §1 before every
session. If this file and the spec disagree, the spec wins and this file is
stale - fix it.

This file records the current engineering state and the next technical actions.
Product explanations belong in `README.md`; calibration evidence belongs in
`bench/` and `docs/pricing-agent.md`.

**Submission:** X Layer AI Season. Target **20 August 2026**; deadline 21 August
23:59 UTC. Today: 20 August 2026.

**Current checkpoint:** the corrected source is deployed and proven end to end on
X Layer testnet at block 38581492 and deployed on X Layer mainnet at block
68445915. The mainnet dashboard is live with pricing calibration in progress;
the pool starts empty until an underwriter supplies capital. The post-change
service smoke is complete and no wallet transaction was submitted.

---

## Current state

| Area | State |
|---|---|
| `docs/SPEC.md` | Complete - §1–12, treated as binding |
| Git repository | `Lightlabs-main/xCover`, `main` pushed. Commits authored `Lightlabs-main <lightlabs112@gmail.com>` |
| Monorepo scaffold | pnpm workspace + Foundry project building |
| Chain verification (§3.3) | **Done, all five calls, recorded in `docs/chain-verification.md`** |
| Testnet probe (§3.5) | **Done - Aave absent from testnet, `TestnetVenue` required** |
| `VerifyIntegration.s.sol` (§3.6) | **Written and passing against live mainnet** |
| Solvency invariant (§1.2.4) | **Written and passing** - `test/invariant/CoverPoolSolvency.t.sol`, three properties, 16,384 calls per run. Mutation-checked: removing the check in `_reserve` fails it. |
| System invariant | **Written and passing** - `test/invariant/CoverSystemSolvency.t.sol` drives the pool through `CoverPolicy`, the real issuance path, and adds: a policy holds a reservation iff it is Active or Claimable. Mutation-checked. |
| Contracts | All five: `CoverPool`, `CoverPolicy`, `xCoverVault`, `ClaimResolver`, `PricingRegistry`, plus `IYieldVenue` + `TestnetVenue` + `AaveV3Venue`. **139 tests passing** - 129 off-fork, 10 against live X Layer mainnet. |
| Absence-asserting tests | **All re-checked by mutation.** Both solvency invariants, all eight separation tests and the bytecode scan still catch what they claim. One gap found and closed: `payClaim`'s payout cap was referenced by no test, and `CoverPool` had no unit file - `test/unit/CoverPool.t.sol` now asserts the pool's guards directly. |
| `xCoverVault` | **Written and passing.** One transaction: supply → consume quote → mint policy → mint shares. Plain ERC-4626 `deposit`/`mint` revert by name rather than producing an uncovered position. Refusal, staleness, capacity and terms-mismatch each refuse the deposit with the user's assets untouched. Direct share transfers are disabled until policy and address-keyed position transfer can be atomic. |
| `ClaimResolver` | **Written and passing.** All three triggers with permissionless observation and settlement; samples must cover the full window, stay within the configured maximum gap and remain fresh. No admin override in either direction. |
| Ownership safety | **Resolved in source.** Policy NFTs and vault shares reject direct transfers; mint/burn lifecycle remains available. A future transferable design must move both records atomically. |
| Observation safety | **Resolved in source.** `AaveV3Venue` uses the configured immutable aToken, and mainnet deployment uses Aave's aggregate oracle. Both are verified against live X Layer fork state. |
| Capital epoch safety | **Resolved in source.** A new pool deposit is rejected while zero-value legacy shares remain after a full payout; regression covered in `test/unit/CoverPool.t.sol`. |
| Separation tests (§4.7) | **All five written and passing** - `test/separation/ModelMoneySeparation.t.sol` |
| Fork payout test (§6.1) | **Passing.** `test/fork/ClaimPayout.t.sol` runs deposit → cover → trigger → settlement against the live Aave Pool, paying 50,000 USDT to the holder. The deficit is planted in the live Pool's storage (slot discovered at runtime, not hardcoded) because the real reserve is healthy; everything reacting to it is real Aave bytecode. Also asserts a transient deficit does not pay, and that the claim touches neither the position nor Aave's deficit. |
| `AaveV3Venue` against real Aave | **Passing on a forked X Layer mainnet.** Supplies real USDT, receives real aUSDT, accrues real interest (11.977953 USDT on 50,000 over 30 days), redeems in full. First product contract to run against a real dependency. |
| Deployment scripts | **Written.** `Deploy.s.sol` holds the wiring both networks share; `DeployTestnet` / `DeployMainnet` supply only asset, venue and parameters. Mainnet refuses to run without the testnet record. A simulation deliberately does not write the deployment record - only a real broadcast does. |
| **X Layer testnet (1952)** | **Corrected deployment complete** at block 38581492; `deployments/xlayer-testnet.json` carries the new addresses, terms hash and seven creation transaction hashes. |
| ~~X Layer testnet, original~~ | Superseded, block 38522841. Record preserved at `deployments/xlayer-testnet.superseded-38522841.json`. Cost 0.000196 OKB. |
| **Live testnet lifecycle** | **Complete.** Policy #1 opened, refusal recorded, 2,500 tUSDT deficit induced, five observations mined at 20-block gaps, `ReserveDeficit` evaluated and 2,500 tUSDT paid. |
| Deficit trigger on testnet | **Proven on chain.** Trigger 1 paid 2,500 tUSDT pro rata above the 50 bp floor; policy state is `Paid`, pool capital is 97,500 tUSDT and outstanding cover is zero. |
| X Layer mainnet (196) | **Deployed at block 68445915.** Live Aave V3 wiring and roles verified; pool capital and vault assets are currently zero. |
| Deficit trigger | **Fixed and proven.** Pays pro-rata above a 50 bp floor. Unit, live-fork and corrected testnet lifecycle evidence cover dust rejection, both sides of the floor, pro-rata payout, smallest-share-in-window, empty reserve, rounding and trigger precedence. |
| Threshold derivation | **Negative for the current corpus.** `bench/threshold-derivation.md` records the 50 bp deficit floor and the $0.97 depeg bound; the pricing-agent confidence signal is not monotonic, so no confidence threshold is derived. Remaining runtime values are operator/review parameters. |
| Pricing service | Implemented in `packages/agent`; live mode starts with explicit operating controls, signs prices or refusals, and serves the dashboard. The live Aave data-provider ABI and aggregate-oracle path were corrected; build passes and agent tests pass. |
| Calibration status | **In progress.** The current evidence set does not provide a measured threshold. The selected pricing route is configured separately in `.env`; no wallet transaction was submitted during calibration work. |
| Benchmark corpus | **Assembled - 229 rows, every citation fetched and checked.** 148 incidents cited to `rekt.news`, 81 judged-valid audit findings cited to Code4rena issues, 156 distinct protocols. Method, provenance and stated weaknesses in `bench/README.md`. |
| Benchmark scoring | **Complete, and the result is negative.** 228 of 229 scored. Confidence failed calibration: accuracy is flat at ~99% across every stated-confidence bin, stated 39% against 99% observed, not monotonic. Three controls then showed every route to that accuracy is an artifact - naming the protocol leaks the outcome (17/20 with no evidence), anonymising fixes that (12/20), and retrieval then leaks it instead (99.8% of retrieved neighbours share the scenario's label). See `bench/threshold-derivation.md`. |
| Calibration evidence | **Stopped at evidence controls; no threshold derived.** The same-source scenario corpus passed its offline checks, but evidence did not improve the fixed live sample. See the dated records in `bench/data/`. |
| Confidence threshold | **Not derived, and not derivable from this corpus.** `PRICING_CONFIDENCE_THRESHOLD_BPS` has no measured value; any value placed there is an operator choice and must be labelled as one. The spec's sentence - *the threshold was not chosen, it was measured* - must not be written about this system yet. |
| Disagreement / uncertainty bounds | **Measured across 228 scenarios.** Disagreement mean 993 bp, p90 2,000 bp, max 3,000 bp. Uncertainty loading mean 4,532 bp, p90 6,000 bp, max 7,000 bp. Usable as reviewed bounds if described as distributions of this model's output, not as risk-calibrated limits. |
| API budget | **$9.00 spent, of which ~$4 was avoidable** - a full run was launched on a cost projected from a no-evidence control, understating it by more than half. Measured rates and the rule against cross-projecting are in `bench/README.md`. |
| Frontend | **Working transactional dashboard** in `apps/web`: capital deposits/withdrawals, price/refusal, decision recording, covered deposit, full exit, and public observations. Server endpoints/assets were smoke-tested; a browser executable was unavailable for visual inspection. |
| X account | Not created |

The day-one verification has been executed against live X Layer mainnet,
`AaveV3Venue` has run against the real Aave V3 Pool on a mainnet fork, and the
corrected contract set has completed the deposit, refusal, bounded observation,
deficit trigger and payout lifecycle on X Layer testnet. Mainnet Aave wiring is
deployed and the pricing agent has now read it successfully live.

**The contract correctness, pricing-agent evidence, benchmark evidence, and
transactional presentation are currently caught up for this checkpoint.** What
remains is the operator-controlled funding decision, optional browser visual
inspection, and external submission work: demo video, X account, and first build
post. The continuation order is in `README.md` and `docs/pricing-agent.md`.

## Settled by chain verification

Full evidence in `docs/chain-verification.md`. The decisions these force:

- **`getReserveDeficit` exists and returns cleanly** (returns `0`, no revert;
  pool revision 11). The deficit trigger is buildable as specified. **The
  redemption-failure fallback is not needed as primary** - do not build toward
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
  1952 everywhere - foundry config, frontend chain config, deployment records.
- RPC rate limit is **100 rps per IP** on both networks. This constrains keeper
  polling frequency (§5.5); design for it rather than discovering it in
  production.

---

## Immediate next actions

1. **Keep calibration in progress.** The current corpus does not produce a
   measured threshold. Producing a usable threshold needs negative scenarios
   drawn from the same source and vocabulary as the positives,
   which is a sourcing problem, not a budget one. If a new corpus is attempted,
   run the two free diagnostics and then the $0.25 control before any full run.
2. **Keep the selected pricing route explicit.** Any value put in
   `PRICING_CONFIDENCE_THRESHOLD_BPS` to let the service start must be labelled
   as an operator choice in `.env.example`, `docs/pricing-agent.md`, and the
   README until calibration supplies a measured value.
3. **Keep the published result honest.** The README now records the negative
   calibration result: the confidence signal failed and the benchmark's own
   weaknesses were measured and published. No live quote has been issued.
4. The corrected testnet venue has a non-zero deficit from the completed payout
   lifecycle, so the agent must refuse there until a clean eligible venue exists.
5. Resolve the calibration credential blocker by verifying the configured
   pricing endpoint and credentials. Do not proceed to browser or wallet actions
   first.
6. After calibration access is verified, inspect the served dashboard visually
   without connecting a funded wallet. No `depositCapital`, `recordDecision`, or
   `depositCovered` call is authorized until the owner chooses the amount.
7. When ready, fund only the owner-selected small mainnet underwriting pool,
   then run the fresh quote → record decision → covered deposit sequence. Finish
   the demo video, X account, and first build post.

---

## Open questions for the owner

- **Mainnet capital: resolved in principle - owner will fund.** Amounts do not
  need to be large: cover written can never exceed capital supplied, so a small
  book is the same product with a smaller book, not a degraded one. Working
  minimum is ~100 USDT as pool capital, ~50 USDT as the covered deposit (same
  wallet is fine), plus OKB for gas. Needed at deployment, not before. The README
  must state the book size plainly rather than implying scale.
- No remaining design choice is waiting on the owner for the current build:
  non-transferability and the 5,000 bp testnet demo floor are now the recorded
  implementation choices.

---

## Blocked

No code blocker remains in the verified batch. The pricing agent and corpus are
implemented, but the current corpus produced no calibration-derived confidence
threshold; further spending on the same corpus will not change that result.
Mainnet is blocked on deployer funding and gas. The corrected testnet venue is
also intentionally ineligible because its proven payout left a non-zero deficit.

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

| 17 Aug 2026 | Deployer key funded on testnet and a separate pricer key generated. Found and resolved a spec/code divergence: `ClaimResolver` was bound to `IAaveV3Pool`, which made every trigger unreadable on testnet - rebound to `IYieldVenue` via `observeReserve`. Added `TestnetUSDT` and `TestnetVenue.induceDeficit` so the testnet lifecycle is reachable at all. Wrote the deployment scripts, **deployed the full set to X Layer testnet (1952)**, and ran the whole path on chain including a 10,000 tUSDT claim paid to the holder. 116 tests passing. `docs/deployments.md` written. Total spend 0.000252 OKB. |

| 17 Aug 2026 | Redeployed the then-current full set to X Layer testnet at block 38540175, regenerated the pricer key, and re-ran the lifecycle on chain: policy #1, a recorded refusal, a partial 2,500 write-off, 5 observations, and 10,000 tUSDT paid. That historical run settled as `RedemptionFailure` because the venue holds one position and the old 10,000 bp floor outranked the deficit trigger. The current source changes are not in that deployment; details are in `docs/deployments.md`. |
| 17 Aug 2026 | Re-checked every absence-asserting test by mutation. The invariants and separation suite all hold. Found that `payClaim`'s payout cap had no test at all and that `CoverPool` had no unit file: the invariant handler bounded the payout to `reserved + 1`, so the fuzzer could overpay by one wei and deleting the cap left every invariant green. Over-paying is theft rather than insolvency, so no invariant can see it - `test/unit/CoverPool.t.sol` added to assert the pool's guards directly. |
| 17 Aug 2026 | Closed the deficit-trigger gap. Ten unit tests and two fork tests written for the pro-rata payout and the 50 bp floor, each mutation-checked against the original bug. Re-ran the fork suite, which had not run since the change: two tests failed because the fixed 250,000 USDT it plants is 49.8 bp of the live reserve and now sits under the floor, and the transient-deficit test was passing for that reason rather than the one it names. Fork tests now size the deficit as a share of the live reserve. 127 tests passing. `bench/threshold-derivation.md` written. |
| 17 Aug 2026 | Correctness batch completed in source: fixed Aave oracle/aToken wiring, disabled unsafe independent policy/share transfers, enforced full-window bounded-cadence observations, fixed zero-capital share epochs, and set the next testnet demo floor to 5,000 bp. Full suite: 139 passing; live fork: 10 passing. |
| 18 Aug 2026 | Built the 229-row cited corpus and scored it in full. The confidence signal failed calibration - accuracy flat at ~99% across every bin, stated 39% against 99% observed, not monotonic - so no threshold is derived. Three controls then established that the accuracy itself is an artifact: naming the protocol scored 17/20 with no evidence at all, anonymising dropped it to 12/20, and with retrieval restored 99.8% of retrieved neighbours carried the scenario's own label, so 54/54 was label propagation. The cause is structural - the two halves come from different sources written in different vocabulary - and is recorded in `bench/README.md` with the measured cost model. $9.00 spent, ~$4 of it avoidable through a bad cost projection. Technical record updated in `bench/` and `docs/pricing-agent.md`. |
| 18 Aug 2026 | Audited the pricing service against the live endpoint, corrected the request path and structured-response handling, and added validation for live-chain evidence. Also paired the chain descriptor to the environment, made replay lookup case-insensitive, and added six tests including a fourteen-reason gate table. Agent and contract test suites passed; the new absence assertions were mutation-checked. |
| 18 Aug 2026 | Reconciled public status after the benchmark and pricing-service work. Confirmed the corpus is complete, kept calibration in progress, and updated the product and service documentation. No dashboard files were created yet; the next code slice was the `apps/web` presentation, followed by a funded mainnet preflight. |
| 18 Aug 2026 | Broadcast corrected testnet set at block 38581492 and merged seven creation transaction hashes into the deployment record. Completed the live lifecycle: policy #1, signed refusal, 2,500 tUSDT induced deficit, five observations at 20-block gaps, trigger 1 (`ReserveDeficit`), and 2,500 tUSDT settlement. Direct reads confirmed policy `Paid`, pool capital 97,500 tUSDT, outstanding cover 0, and venue balance 7,500 tUSDT against 10,000 owed. |
| 19 Aug 2026 | Added a staged calibration gate with a fixed manifest, balanced historical-outcome retrieval, request pacing, resumable quota handling, and paired AUC/accuracy/Brier checks. The candidate did not improve the fixed sample, so no larger run was started. Agent tests and the TypeScript build passed. |
| 20 Aug 2026 | Completed the post-change service build and tests. Live smoke exposed and fixed two Aave ABI mismatches and an invalid oracle call; the service now uses the verified reserve tuples and aggregate oracle. A mainnet request returned a signed refusal because the pool had no available capacity, and the decision replayed to the exact hash. Dashboard endpoints/assets served and browser JavaScript parsed; no wallet transaction or funding occurred. |
| 20 Aug 2026 | Tested the configured universal route without printing credentials. The gateway returned verification HTML rather than a model response, so no calibration call completed. Browser inspection and capital funding remained paused. |

Update this table at the end of every session (§1.3).
