# xCover — Progress & Handoff

**Single source of truth for scope:** `docs/SPEC.md`. Read §1 before every
session. If this file and the spec disagree, the spec wins and this file is
stale — fix it.

**Starting cold?** `CLAUDE.md` is the entry point and loads automatically in a
Claude Code session; `HANDOFF.md` has the full cold-start detail. This file
carries only current state and what happens next.

**Submission:** X Layer AI Season. Target **20 August 2026**; deadline 21 August
23:59 UTC. Today: 18 August 2026.

**Current checkpoint:** the corrected source is deployed and proven end to end on
X Layer testnet at block 38581492. Mainnet remains undeployed.

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
| Contracts | All five: `CoverPool`, `CoverPolicy`, `xCoverVault`, `ClaimResolver`, `PricingRegistry`, plus `IYieldVenue` + `TestnetVenue` + `AaveV3Venue`. **139 tests passing** — 129 off-fork, 10 against live X Layer mainnet. |
| Absence-asserting tests | **All re-checked by mutation.** Both solvency invariants, all eight separation tests and the bytecode scan still catch what they claim. One gap found and closed: `payClaim`'s payout cap was referenced by no test, and `CoverPool` had no unit file — `test/unit/CoverPool.t.sol` now asserts the pool's guards directly. |
| `xCoverVault` | **Written and passing.** One transaction: supply → consume quote → mint policy → mint shares. Plain ERC-4626 `deposit`/`mint` revert by name rather than producing an uncovered position. Refusal, staleness, capacity and terms-mismatch each refuse the deposit with the user's assets untouched. Direct share transfers are disabled until policy and address-keyed position transfer can be atomic. |
| `ClaimResolver` | **Written and passing.** All three triggers with permissionless observation and settlement; samples must cover the full window, stay within the configured maximum gap and remain fresh. No admin override in either direction. |
| Ownership safety | **Resolved in source.** Policy NFTs and vault shares reject direct transfers; mint/burn lifecycle remains available. A future transferable design must move both records atomically. |
| Observation safety | **Resolved in source.** `AaveV3Venue` uses the configured immutable aToken, and mainnet deployment uses Aave's aggregate oracle. Both are verified against live X Layer fork state. |
| Capital epoch safety | **Resolved in source.** A new pool deposit is rejected while zero-value legacy shares remain after a full payout; regression covered in `test/unit/CoverPool.t.sol`. |
| Separation tests (§4.7) | **All five written and passing** — `test/separation/ModelMoneySeparation.t.sol` |
| Fork payout test (§6.1) | **Passing.** `test/fork/ClaimPayout.t.sol` runs deposit → cover → trigger → settlement against the live Aave Pool, paying 50,000 USDT to the holder. The deficit is planted in the live Pool's storage (slot discovered at runtime, not hardcoded) because the real reserve is healthy; everything reacting to it is real Aave bytecode. Also asserts a transient deficit does not pay, and that the claim touches neither the position nor Aave's deficit. |
| `AaveV3Venue` against real Aave | **Passing on a forked X Layer mainnet.** Supplies real USDT, receives real aUSDT, accrues real interest (11.977953 USDT on 50,000 over 30 days), redeems in full. First product contract to run against a real dependency. |
| Deployment scripts | **Written.** `Deploy.s.sol` holds the wiring both networks share; `DeployTestnet` / `DeployMainnet` supply only asset, venue and parameters. Mainnet refuses to run without the testnet record. A simulation deliberately does not write the deployment record — only a real broadcast does. |
| **X Layer testnet (1952)** | **Corrected deployment complete** at block 38581492; `deployments/xlayer-testnet.json` carries the new addresses, terms hash and seven creation transaction hashes. |
| ~~X Layer testnet, original~~ | Superseded, block 38522841. Record preserved at `deployments/xlayer-testnet.superseded-38522841.json`. Cost 0.000196 OKB. |
| **Live testnet lifecycle** | **Complete.** Policy #1 opened, refusal recorded, 2,500 tUSDT deficit induced, five observations mined at 20-block gaps, `ReserveDeficit` evaluated and 2,500 tUSDT paid. |
| Deficit trigger on testnet | **Proven on chain.** Trigger 1 paid 2,500 tUSDT pro rata above the 50 bp floor; policy state is `Paid`, pool capital is 97,500 tUSDT and outstanding cover is zero. |
| X Layer mainnet (196) | Not deployed. Deployer balance is zero there; funding still owed. |
| Deficit trigger | **Fixed and proven.** Pays pro-rata above a 50 bp floor. Unit, live-fork and corrected testnet lifecycle evidence cover dust rejection, both sides of the floor, pro-rata payout, smallest-share-in-window, empty reserve, rounding and trigger precedence. |
| Threshold derivation | **Started for contract terms only.** `bench/threshold-derivation.md` records the 50 bp deficit floor and the $0.97 depeg bound. Pricing-agent confidence and runtime controls are not yet derived; provenance is in `docs/pricing-agent.md`. |
| Pricing agent | Scaffolded in `packages/agent`; **11 unit tests passing**, covering signing, canonical replay hashing, the two-pass gate/refusal path, fourteen named gate reasons, evidence citation, and environment pairing. The assessment call now runs on the official SDK against `claude-opus-5` and has been **exercised end to end against the live API**. Corpus and reviewed runtime controls remain pending, so no quote is claimed. |
| Benchmark corpus | **Assembled — 229 rows, every citation fetched and checked.** 148 incidents cited to `rekt.news`, 81 judged-valid audit findings cited to Code4rena issues, 156 distinct protocols. Method, provenance and stated weaknesses in `bench/README.md`. |
| Benchmark scoring | **Complete, and the result is negative.** 228 of 229 scored. Confidence failed calibration: accuracy is flat at ~99% across every stated-confidence bin, stated 39% against 99% observed, not monotonic. Three controls then showed every route to that accuracy is an artifact — naming the protocol leaks the outcome (17/20 with no evidence), anonymising fixes that (12/20), and retrieval then leaks it instead (99.8% of retrieved neighbours share the scenario's label). See `bench/threshold-derivation.md`. |
| Confidence threshold | **Not derived, and not derivable from this corpus.** `PRICING_CONFIDENCE_THRESHOLD_BPS` has no measured value; any value placed there is an operator choice and must be labelled as one. The spec's sentence — *the threshold was not chosen, it was measured* — must not be written about this system yet. |
| Disagreement / uncertainty bounds | **Measured across 228 scenarios.** Disagreement mean 993 bp, p90 2,000 bp, max 3,000 bp. Uncertainty loading mean 4,532 bp, p90 6,000 bp, max 7,000 bp. Usable as reviewed bounds if described as distributions of this model's output, not as risk-calibrated limits. |
| API budget | **$9.00 spent, of which ~$4 was avoidable** — a full run was launched on a cost projected from a no-evidence control, understating it by more than half. Measured rates and the rule against cross-projecting are in `bench/README.md`. |
| Frontend | Not started |
| X account | Not created |

The day-one verification has been executed against live X Layer mainnet,
`AaveV3Venue` has run against the real Aave V3 Pool on a mainnet fork, and the
corrected contract set has completed the deposit, refusal, bounded observation,
deficit trigger and payout lifecycle on X Layer testnet. The Aave integration
remains fork-proven until the mainnet deployment happens.

**The contract correctness and testnet evidence work is currently caught up. What
remains is the submission pipeline:** pricing agent, benchmark corpus, funded
mainnet deployment, and presentation. See
`HANDOFF.md` §6 for the exact continuation order.

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

1. **Do not re-run the scoring.** The calibration question is settled and the
   answer is negative — see `HANDOFF.md` §4a. Producing a usable threshold needs
   negative scenarios drawn from the same source and vocabulary as the positives,
   which is a sourcing problem, not a budget one. If a new corpus is attempted,
   run the two free diagnostics and then the $0.25 control before any full run.
2. **Decide the deployed model and label the threshold honestly.** `.env` names
   `claude-opus-5`; the benchmark ran on `claude-sonnet-5` at `effort: low`, so
   the existing scores do not calibrate an Opus 5 deployment. Whatever value is
   put in `PRICING_CONFIDENCE_THRESHOLD_BPS` to let the agent start must be
   described as an operator choice in `.env.example`, `docs/pricing-agent.md` and
   the README.
3. **Write the README section on the negative result.** It is the strongest
   quantitative claim available: the confidence signal was measured, it failed,
   and the benchmark's own weaknesses were measured and published. State plainly
   that no live quote has been issued.
4. The corrected testnet venue has a non-zero deficit from the completed payout
   lifecycle, so the agent must refuse there until a clean eligible venue exists.
5. Fund mainnet, rerun `VerifyIntegration.s.sol`, deploy with `DeployMainnet.s.sol`,
   verify roles/oracle/venue/terms on chain, and commit the mainnet record only
   after the corrected testnet record is present.
6. Finish the frontend, README figures, demo video, X account and first build post.

---

## Open questions for the owner

- **Mainnet capital: resolved in principle — owner will fund.** Amounts do not
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

No code blocker remains in the verified batch. The pricing-agent scaffold is
implemented and its corpus exists, but scoring is **blocked on Anthropic API
credit** (`credit balance is too low`), so no gate threshold is derived yet;
mainnet is blocked on deployer funding and gas.

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

| 17 Aug 2026 | Redeployed the then-current full set to X Layer testnet at block 38540175, regenerated the pricer key, and re-ran the lifecycle on chain: policy #1, a recorded refusal, a partial 2,500 write-off, 5 observations, and 10,000 tUSDT paid. That historical run settled as `RedemptionFailure` because the venue holds one position and the old 10,000 bp floor outranked the deficit trigger. The current source changes are not in that deployment; details are in `docs/deployments.md`. |
| 17 Aug 2026 | Re-checked every absence-asserting test by mutation. The invariants and separation suite all hold. Found that `payClaim`'s payout cap had no test at all and that `CoverPool` had no unit file: the invariant handler bounded the payout to `reserved + 1`, so the fuzzer could overpay by one wei and deleting the cap left every invariant green. Over-paying is theft rather than insolvency, so no invariant can see it — `test/unit/CoverPool.t.sol` added to assert the pool's guards directly. |
| 17 Aug 2026 | Closed the deficit-trigger gap. Ten unit tests and two fork tests written for the pro-rata payout and the 50 bp floor, each mutation-checked against the original bug. Re-ran the fork suite, which had not run since the change: two tests failed because the fixed 250,000 USDT it plants is 49.8 bp of the live reserve and now sits under the floor, and the transient-deficit test was passing for that reason rather than the one it names. Fork tests now size the deficit as a share of the live reserve. 127 tests passing. `bench/threshold-derivation.md` written. |
| 17 Aug 2026 | Correctness batch completed in source: fixed Aave oracle/aToken wiring, disabled unsafe independent policy/share transfers, enforced full-window bounded-cadence observations, fixed zero-capital share epochs, and set the next testnet demo floor to 5,000 bp. Full suite: 139 passing; live fork: 10 passing. |
| 18 Aug 2026 | Built the 229-row cited corpus and scored it in full. The confidence signal failed calibration — accuracy flat at ~99% across every bin, stated 39% against 99% observed, not monotonic — so no threshold is derived. Three controls then established that the accuracy itself is an artifact: naming the protocol scored 17/20 with no evidence at all, anonymising dropped it to 12/20, and with retrieval restored 99.8% of retrieved neighbours carried the scenario's own label, so 54/54 was label propagation. The cause is structural — the two halves come from different sources written in different vocabulary — and is recorded in `bench/README.md` with the measured cost model. $9.00 spent, ~$4 of it avoidable through a bad cost projection. Handover written to `HANDOFF.md` §4a. |
| 18 Aug 2026 | Audited the pricing agent against the live API and found it could never have quoted: the configured `claude-3-5-sonnet-20241022` returns HTTP 404 for this key, and the hand-rolled request also sent `temperature`, which the current models reject. Both faults surfaced only as a refusal, which is a correct outcome here and so hid them. Moved the call to the official SDK on `claude-opus-5` with adaptive thinking, dropped the sampling parameters, and ran a full assessment end to end against the live API. The run exposed a third fault: the model cited `live-chain-state` for facts read from the chain and the citation validator rejected the whole assessment — that id is now reserved, named in the prompt, and refused to the corpus. Also paired the viem chain descriptor to the environment, made replay lookup case-insensitive, and added six tests including a fourteen-reason gate table. 11 agent tests and 129 off-fork contract tests passing; the two new absence assertions were mutation-checked. |
| 18 Aug 2026 | Broadcast corrected testnet set at block 38581492 and merged seven creation transaction hashes into the deployment record. Completed the live lifecycle: policy #1, signed refusal, 2,500 tUSDT induced deficit, five observations at 20-block gaps, trigger 1 (`ReserveDeficit`), and 2,500 tUSDT settlement. Direct reads confirmed policy `Paid`, pool capital 97,500 tUSDT, outstanding cover 0, and venue balance 7,500 tUSDT against 10,000 owed. |

Update this table at the end of every session (§1.3).
