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
| Contracts | `CoverPool`, `CoverPolicy`, `PricingRegistry`, `IYieldVenue` + `TestnetVenue` + `AaveV3Venue`. 70 tests passing. |
| Separation tests (§4.7) | **All five written and passing** — `test/separation/ModelMoneySeparation.t.sol` |
| `AaveV3Venue` against real Aave | **Passing on a forked X Layer mainnet.** Supplies real USDT, receives real aUSDT, accrues real interest (11.977953 USDT on 50,000 over 30 days), redeems in full. First product contract to run against a real dependency. |
| Pricing agent | None written |
| Benchmark corpus | Not started |
| Frontend | Not started |
| X account | Not created |

The day-one verification has been executed against live X Layer mainnet. No
product contract has run against a real dependency yet; per §1.3 nothing below
the verification line may be marked done until it has.

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

1. `ClaimResolver` — deterministic evaluation of the three triggers with block
   sampling, holding `CLAIM_ROLE` on both `CoverPool` and `CoverPolicy`.
2. `xCoverVault` (ERC-4626) tying deposit → venue → quote → policy into one
   transaction, and reverting with a clear reason when the agent declined.
3. `test/fork/ClaimPayout.t.sol` — the full payout path on a mainnet fork.
4. Deploy the full set to X Layer testnet (chain 1952) and record addresses, tx
   hashes, block numbers and timestamps in `deployments/xlayer-testnet.json`.
   Testnet must provably precede mainnet; it is an eligibility gate.
5. Start the benchmark corpus. Long-lead item: it gates the threshold, and the
   threshold gates the agent's `DECLINE_TO_QUOTE` behaviour.
6. Create the X account and publish the first build post.

---

## Open questions for the owner

- Source of real capital for the mainnet pool and the live covered position
  (§11 requires both to be real).
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

Update this table at the end of every session (§1.3).
