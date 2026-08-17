# xCover

Depositor cover for Aave V3 on X Layer, priced per-block by an agent that may
decline to quote, minted in the same transaction as the deposit.

**Submission target 20 August 2026.** Deadline 21 August 23:59 UTC. Submit on the
20th, never on deadline day.

---

## Start here, every session

Read these three, in this order, before doing anything else:

1. **`docs/SPEC.md` §1** — standing instructions and the absolute rules. The
   spec is the single source of truth. If code and spec disagree, one of them is
   wrong and it gets resolved explicitly, never silently.
2. **`HANDOFF.md`** — cold-start setup, verified chain facts, git identity, the
   codespace push trap, and what is built versus what is not.
3. **`PROGRESS.md`** — current state, next actions, session log.

Update `PROGRESS.md` at the end of every session. Update `HANDOFF.md` whenever a
fact in it stops being true — it is the only thing that survives a new machine,
so a stale entry will mislead a future session that has no other context.

## First commands on a fresh machine

Foundry is not preinstalled on a blank codespace.

```bash
curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup
git submodule update --init --recursive
cd packages/contracts && forge build
forge script script/VerifyIntegration.s.sol --rpc-url https://rpc.xlayer.tech
```

That last command must print `All integration assumptions hold.` If it reverts,
an on-chain assumption changed: read the failing require, update
`docs/chain-verification.md`, and resolve it before writing code. Do not work
around it.

## Absolute rules

- **No mocks** standing in for real dependencies in anything presented as
  working. A demo backed by a mock is a lie by omission.
- **Deterministic code controls money.** The agent prices risk; it never moves
  funds and never decides a claim outcome. This separation is enforced by tests,
  not by convention.
- **Refusal is a first-class outcome.** `DECLINE_TO_QUOTE` is correct behaviour
  when data is insufficient. Never widen a quote to avoid refusing.
- **Nothing is "done"** until it has run end to end at least once against a real
  dependency on a real chain.
- Propose the interface before implementing it. Invariants before
  implementations.

## Commits — binding

```bash
git config user.name  "Lightlabs-main"
git config user.email "lightlabs112@gmail.com"
```

Set locally on the repo on any new machine. The `melindacharles@` account must
never appear in the history.

Short imperative subject describing the change itself. **No** phase or day
numbers, no gate language, no emoji, no ticket prefixes, no `Co-Authored-By`, no
"Generated with", no tool or model name anywhere, ever. The schedule is planning
context and must never leak into a commit message.

```
good:  add solvency invariant test for CoverPool
bad:   Phase 2: CoverPool ✅
```

**Pushing from a codespace:** the ambient `GITHUB_TOKEN` is refused for pushes to
this repo and overrides working credentials, while still reporting `push: true`
from the API. Prefix git and gh commands with `GITHUB_TOKEN=`:

```bash
GITHUB_TOKEN= git push origin main
```

Plain `gh auth login` exits without prompting, claiming you are already
authenticated. Use `GITHUB_TOKEN= gh auth login`.

## Chain facts that change decisions

Full evidence in `docs/chain-verification.md`; addresses in
`packages/contracts/src/XLayerAddresses.sol`.

- X Layer mainnet is **196** (`https://rpc.xlayer.tech`). Testnet is **1952**
  (`https://testrpc.xlayer.tech`) — **not 195**, which is deprecated.
- **`getReserveDeficit` exists and returns cleanly.** The deficit trigger is the
  primary claim condition; the redemption-failure fallback is not needed and
  should not be built toward.
- **Aave V3 is not deployed on X Layer testnet.** `IYieldVenue` with a swappable
  implementation is required, not optional: `TestnetVenue` on testnet,
  `AaveV3Venue` on mainnet. Deployment docs must state this plainly.
- Normal oracle conditions are already **~10 bp off peg**, so the depeg
  threshold must clear that or it fires on noise.
- RPC rate limit is **100 rps per IP**, which caps keeper polling frequency.
- Launch covers **USDT only**.

## Where things live

```
docs/SPEC.md                      binding spec, §1-12
docs/chain-verification.md        raw on-chain evidence with block numbers
README.md                         public-facing; build status and limitations
HANDOFF.md                        cold-start handoff, survives a new machine
PROGRESS.md                       current state and next actions
packages/contracts/               Foundry project, solc 0.8.28
  src/CoverPool.sol               capital, solvency accounting, claims
  src/CoverPolicy.sol             ERC-721 positions and lifecycle
  src/xCoverVault.sol             deposit and cover in one transaction
  src/ClaimResolver.sol           windowed trigger sampling and settlement
  src/PricingRegistry.sol         signed quotes and recorded refusals
  src/venues/                     AaveV3Venue (mainnet), TestnetVenue (testnet)
  src/XLayerAddresses.sol         verified addresses
  test/invariant/                 two solvency suites — never cut these
  test/separation/                §4.7 model-and-money separation
  test/fork/                      against live X Layer mainnet
  script/VerifyIntegration.s.sol  asserts the integration still holds
deployments/                      per-chain address records, committed evidence
bench/                            benchmark corpus and threshold derivation
```

## State, briefly

All five §4 contracts are written; 109 tests pass; **nothing is deployed**. The
fork payout test runs the full path against live Aave. Next up is deployment
scripts and the testnet deployment (chain 1952), which must provably precede
mainnet. `HANDOFF.md` §4 has the role-wiring table and the design decisions that
are load-bearing; §5 lists traps already paid for once — read both before writing
contract or test code.

## Two testing rules learned here the hard way

- **A green invariant run can prove nothing.** Check `invariant_CallSummary`
  (`forge test --match-test invariant_CallSummary -vv`) to confirm the fuzzer did
  real work before trusting a pass.
- **Mutation-check anything asserting an absence.** Break it deliberately, watch
  the test fail, restore. A test never seen failing is not evidence.

## Never cut

The solvency invariant test, the fork payout test, the three separation tests,
the refusal path, the testnet→mainnet sequence.

If time runs short, reduce benchmark size (never drop it), then simplify the
capital-provider UI, then reduce keeper frequency — in that order.
