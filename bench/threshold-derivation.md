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

---

# Confidence gate — the derivation, and why it does not produce a threshold

**Result: the confidence signal failed calibration on this corpus, so no confidence
threshold is derived from it.** SPEC §5.4 anticipates this branch explicitly — *"if
confidence is not monotonic with accuracy, it is not a usable signal and the README
must say so"* — and this is that case. What follows is the working.

## The run

229 scenarios, 228 scored, one unscored (`incident-compound-rekt`: the model returned
malformed JSON; it is recorded as an error, never as a guess). Leave-one-out retrieval,
two framings per scenario, `claude-sonnet-5` at `effort: low`. Raw per-scenario output is
in `data/scores-sonnet5-low.jsonl`; the control is in `data/control-sonnet5-low.jsonl`.

## 1. Bin by stated confidence, plot stated against observed

| Stated confidence | n | Observed accuracy | Mean stated |
|---|---|---|---|
| 0–20% | 5 | 100.0% | 15.0% |
| 20–30% | 35 | 94.3% | 23.3% |
| 30–40% | 92 | 100.0% | 31.2% |
| 40–50% | 32 | 100.0% | 42.4% |
| 50–60% | 16 | 100.0% | 54.5% |
| 60–70% | 47 | 100.0% | 61.7% |
| 70–80% | 1 | 100.0% | 70.0% |

## 2. Monotonicity — fails

Accuracy is not non-decreasing in stated confidence: it is 100% in the lowest bin, dips
to 94.3% in the second, and is 100% everywhere above. The curve is **flat**, not sloped.
Splitting at the median confidence (35%) gives 100.0% accuracy above and 98.2% below — a
1.8 point difference across the entire range of the signal.

A gate needs confidence to separate cases it should decline from cases it should price.
This one does not separate anything, so there is no operating point to choose.

## 3. The overconfidence offset — measured, and negative

Mean stated confidence 39.3%; observed accuracy 99.1%. The offset is **−60 points**: the
model is not overconfident, it is severely *under*confident. Correcting for it would mean
lowering the gate until it declines almost nothing, which is not a safety property.

## 4. Choosing an operating point by cost asymmetry — not possible here

| Threshold | Quotes | Accuracy on quotes | Refusals | Refusal precision |
|---|---|---|---|---|
| 20% | 223 | 36.3% | 5 | 100.0% |
| 30% | 188 | 43.1% | 40 | 100.0% |
| 40% | 96 | 71.9% | 132 | 90.9% |
| 50% | 64 | 87.5% | 164 | 84.8% |
| 60% | 48 | 97.9% | 180 | 81.1% |
| 65% | 17 | 100.0% | 211 | 69.7% |
| 70% | 1 | 100.0% | 227 | 64.8% |

This table looks like a usable trade-off and is not one. 35.5% of the corpus is `no_loss`,
so a gate that quotes blindly is already "36% accurate on quotes". Accuracy on quotes rises
with the threshold because the surviving sample shifts toward the minority class, not
because the gate is selecting well — and by the point it reads 100%, it is quoting 17 cases
out of 228. Reading a threshold off this table would be reading the class mix.

## 5. Why the accuracy figure itself cannot be published as competence

Overall directional accuracy is 99.1%. That is not credible as risk prediction, and the
control run says why: **with retrieval disabled entirely, accuracy was 17/20 against a
chance rate of 10/20.** The model recognises Balancer, Yearn and Badger as protocols that
were exploited. The benchmark is substantially measuring recall of well-known incidents,
not judgement from cited evidence. See `README.md` for the corpus's framing weaknesses.

The one thing the control did show in the model's favour: removing the evidence dropped
mean stated confidence on loss scenarios from 5,570 bp to 3,450 bp. It reports lower
confidence when it has less to go on. That is the right direction — it is simply not
strong enough, or monotonic enough, to gate on.

## 6. What this means for the deployed agent

`PRICING_CONFIDENCE_THRESHOLD_BPS` is **not derived and must not be presented as derived.**
The sentence §5.4 asks for — *the threshold was not chosen, it was measured* — cannot
honestly be written about this system today. Any value placed in that variable to make the
agent start is an operator's choice and must be labelled as one, in `.env.example`, in
`docs/pricing-agent.md` and in the README.

Two measurements from the same run are usable as reviewed bounds, since they are
distributions of the model's own output rather than claims about its accuracy:

- **Ensemble disagreement**: mean 993 bp, p90 2,000 bp, max 3,000 bp across 228 scenarios.
- **Uncertainty loading**: mean 4,532 bp, p90 6,000 bp, max 7,000 bp.

## 7. What would fix this

The corpus is too easy and it leaks. A usable calibration needs scenarios the model cannot
resolve from memory — recent or obscure events, and situations described by their state
rather than by their protocol's name. That is a corpus rebuild, not a re-run, and it is
not attempted here.
