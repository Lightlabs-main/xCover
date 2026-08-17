# Threshold derivation

Every number in a policy's `Terms` decides whether someone gets paid. This file
records where each one came from, so a reviewer can check the reasoning rather
than trust the value. A threshold with no entry here is a reasoned default, not a
derived one, and must say so.

Measurements are dated and attributed to a chain and a block wherever the value
was read rather than chosen.

---

## `deficitFloorBps` — 50 bp

**What it gates.** A reserve deficit below this share of the reserve is not a
covered event. Above it, the payout is the depositor's pro-rata share of the
hole.

**Why a floor is needed at all.** A deficit is Aave's record of bad debt, created
whenever a liquidation leaves an account with zero collateral and non-zero debt.
That is routine, not exceptional. It is cleared only by a permissioned Umbrella
call with no time constraint, so once a reserve's deficit is non-zero it stays
non-zero indefinitely. "Non-zero deficit" is therefore Aave's ordinary resting
state, not a distress signal.

**The measurement.** Ethereum Aave V3, 17 August 2026:

| Reserve | Deficit | Supplied | Share |
|---|---|---|---|
| USDT | 0.830980 | 2,971,945,009 | 0.0000028 bp |
| cbBTC | 1 satoshi | — | ~0 bp |
| WETH | — | — | 243 bp |

**27 of 67 reserves carried a non-zero deficit at the same moment.** The spread
between resting dust (0.0000028 bp) and a materially damaged reserve (WETH, 243
bp) is roughly eight orders of magnitude, so a floor anywhere in the wide gap
between them separates the two populations. 50 bp sits inside that gap with
margin on both sides: about 18 million times the observed dust, and about 5x
below the damaged reserve, so neither a routine liquidation nor a rounding
artefact reaches it, and a real loss clears it comfortably.

**Why not zero.** The first version of this contract treated any non-zero deficit
as a total loss and paid full cover. Against the USDT reading above, that pays a
10,000 claim on an implied depositor loss of roughly one part in 3.6 billion.
It would have looked correct until it fired: X Layer's reserves all read zero
today only because that market is young.

**Why a share and not an absolute figure.** The same absolute deficit means
different things in a 50M reserve and a 3B one, and a reserve grows with interest
and with new depositors. An absolute threshold silently drifts in strictness over
time. This is not hypothetical — the fork test planted a fixed 250,000 USDT,
which is 49.8 bp of X Layer's 50.2M USDT reserve and therefore lands just under
this floor by a whisker; the test now sizes the deficit as a share of the live
reserve for exactly that reason.

**Tests that hold this in place.** `test_AaveRestingDeficitIsNotAClaim` uses the
USDT figures above verbatim. `test_DeficitJustBelowTheFloorIsNotACoveredEvent`
and `test_DeficitAtTheFloorTriggersAndPaysThatShare` assert both sides of the
boundary. `test_SubFloorDeficitDoesNotPayOnLiveAave` proves the rejection against
the live Aave Pool. All four have been mutation-checked.

---

## `depegLowerBound` — $0.97

**What it gates.** An oracle price below this is a depeg. The payout is the
shortfall against peg, not full cover, because the depositor still holds an asset
worth something.

**The measurement.** X Layer mainnet, block 68179960, 17 August 2026: the Aave
oracle reported USDT at `99896524` = **$0.99896524**. Normal conditions are
therefore already **~10 bp off peg**.

A threshold set near peg fires on that drift continuously. $0.97 sits 300 bp
below peg — 30x the observed normal deviation — so ordinary oracle noise cannot
reach it while a genuine stablecoin failure passes it easily.

**Test.** `test_NormalOffPegDriftDoesNotTrigger` uses the live reading above and
asserts it does not pay.

---

## Not yet derived

These are reasoned defaults in `script/Deploy*.s.sol`, flagged as such in the
code and in `docs/deployments.md`. They must be reviewed before mainnet.

- `windowBlocks` / `minSamples` — the sampling window and the evidence required
  inside it. Constrained from below by the flash-loan defence and from above by
  the keeper cadence the 100 rps RPC limit allows.
- `liquidityFloorBps` — currently 10,000, i.e. redeemable liquidity below the
  policy's own cover is a redemption failure.
- The waiting period and the daily issuance cap.
