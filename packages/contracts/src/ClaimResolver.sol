// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPolicy} from "./interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "./interfaces/IYieldVenue.sol";

/// @title ClaimResolver
/// @notice Deterministic evaluation of the covered events, and settlement of the claims they
///         trigger (SPEC §4.4).
///
/// @dev **No model, no governance, no discretion.** Nothing in this contract consults a price
///      quote, an agent, or an administrator. It reads chain state, compares it against
///      thresholds that were fixed in the policy's `termsHash` at mint, and reports. There is no
///      function by which any role can approve an untriggered claim or deny a triggered one, and
///      that absence is asserted by the separation tests.
///
///      **Sampling is accumulated, not read backwards.** A single call cannot inspect past
///      blocks, so "the condition held throughout a window" is established by observations
///      recorded as those blocks pass. A single-block read would be manipulable with a flash
///      loan: borrow enough to drain the reserve's liquidity for one block, trigger every policy,
///      repay. Requiring the condition to hold across a window of separately-mined blocks makes
///      that attack cost a sustained position rather than one transaction.
///
///      **Recording is permissionless, and must be.** If only a keeper could record
///      observations, a keeper who simply stopped recording could deny every valid claim without
///      ever calling a function that says "deny". The right to establish what was true is not a
///      privilege here.
///
///      **Terms are verified, not trusted.** The caller supplies the `Terms` struct; this
///      contract hashes it and requires the hash to equal the one fixed in the policy at mint.
///      Thresholds therefore cannot be renegotiated after a loss, by anyone, including the
///      deployer.
contract ClaimResolver is AccessControl {
    /// @notice May settle a triggered claim. Settlement is also permissionless — see `claim`.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice The oracle's base unit for a stablecoin at peg: $1.00 at 8 decimals.
    uint256 public constant PEG_PRICE = 1e8;

    /// @notice The covered events, as evaluated. `None` means no trigger held.
    enum Trigger {
        None,
        ReserveDeficit,
        RedemptionFailure,
        OracleFailure
    }

    /// @notice Thresholds fixed at mint. The hash of this struct is the policy's `termsHash`.
    /// @dev Every field is a number a contract can compare. If a human would have to form a
    ///      judgement about it, it does not belong here and the event is not covered.
    struct Terms {
        address reserve; // covered asset
        address aToken; // its aToken, whose underlying balance is the redeemable liquidity
        uint64 windowBlocks; // the condition must hold across this many blocks
        uint64 minSamples; // and be witnessed at least this many times within them
        uint64 maxObservationGapBlocks; // no unseen gap may exceed this many blocks
        uint256 depegLowerBound; // oracle price below this is a depeg, 8 decimals
        uint256 liquidityFloorBps; // redeemable liquidity below this share of cover is a failure
        uint256 deficitFloorBps; // deficit below this share of the reserve is not a covered loss
    }

    /// @notice One reading of the chain, taken at the block it names.
    struct Observation {
        uint64 blockNumber;
        uint256 deficit; // unbacked obligations the venue records against the reserve
        uint256 price; // the venue's oracle price for the reserve, 8 decimals
        uint256 redeemableLiquidity; // underlying actually available to redeem
        uint256 totalSupplied; // everything supplied to the reserve — the deficit's denominator
    }

    struct AssessmentState {
        uint256 samples;
        uint256 minDeficitBps;
        uint64 newestBlock;
        uint64 previousBlock;
        bool haveSample;
        bool windowCovered;
        bool deficitHeld;
        bool depegHeld;
        bool illiquidityHeld;
    }

    ICoverPool public immutable pool;
    ICoverPolicy public immutable policy;

    /// @notice The venue the covered position sits in, and therefore the source of the readings.
    /// @dev Bound to the interface rather than to `IAaveV3Pool` because the trigger has to be
    ///      readable on both chains: Aave V3 is on X Layer mainnet and is not on X Layer testnet.
    ///      `AaveV3Venue` forwards these reads to the live Aave Pool and oracle; `TestnetVenue`
    ///      answers from its own real on-chain state. The resolver's logic is identical either way,
    ///      which is what makes the testnet lifecycle evidence about the mainnet system.
    IYieldVenue public immutable venue;

    /// @notice Observations per reserve, in block order.
    mapping(address => Observation[]) internal _observations;

    /// @notice Payout fixed at evaluation, in the reserve's decimals.
    mapping(uint256 => uint256) public claimAmount;

    /// @notice Which covered event triggered a policy, for the record.
    mapping(uint256 => Trigger) public triggerOf;

    event ObservationRecorded(
        address indexed reserve,
        uint64 indexed blockNumber,
        uint256 deficit,
        uint256 price,
        uint256 redeemableLiquidity,
        uint256 totalSupplied
    );
    event ClaimTriggered(uint256 indexed policyId, Trigger trigger, uint256 payout);
    event ClaimSettled(uint256 indexed policyId, address indexed to, uint256 amount);

    /// @notice The supplied terms do not hash to the terms fixed in the policy at mint.
    error TermsMismatch(uint256 policyId, bytes32 expected, bytes32 supplied);
    /// @notice The policy is not currently providing cover — expired, cancelled, or still inside
    ///         its waiting period.
    error CoverNotActive(uint256 policyId);
    /// @notice No covered event held across the required window.
    error NoTriggerMet(uint256 policyId);
    /// @notice Fewer observations inside the window than the terms require.
    error InsufficientSamples(uint256 found, uint64 required);
    /// @notice The observations do not reach back to the beginning of the configured window.
    error ObservationWindowNotCovered(uint64 oldestBlock, uint256 requiredStart);
    /// @notice The newest observation is too old to support a current evaluation.
    error ObservationTooOld(uint64 newestBlock, uint256 currentBlock, uint64 maxGap);
    /// @notice Two adjacent observations leave too much of the window unseen.
    error ObservationGapTooLarge(uint64 newerBlock, uint64 olderBlock, uint64 maxGap);
    /// @notice Sampling terms cannot establish a bounded observation cadence.
    error InvalidSamplingTerms();
    /// @notice One observation per block; the chain has not moved since the last one.
    error ObservationAlreadyRecorded(uint64 blockNumber);
    /// @notice The terms describe a different reserve than the policy covers.
    error TermsReserveMismatch();

    constructor(ICoverPool pool_, ICoverPolicy policy_, IYieldVenue venue_, address admin) {
        pool = pool_;
        policy = policy_;
        venue = venue_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // --- observation ----------------------------------------------------------------------

    /// @notice Record what the chain says right now about a reserve.
    /// @dev Permissionless by design — see the contract note. Every value is read here and now
    ///      from the venue; nothing is supplied by the caller, so a hostile caller can only choose
    ///      *when* to record a true reading, never what it says.
    function recordObservation(address reserve, address aToken) external returns (uint256 index) {
        Observation[] storage obs = _observations[reserve];
        if (obs.length > 0 && obs[obs.length - 1].blockNumber == uint64(block.number)) {
            revert ObservationAlreadyRecorded(uint64(block.number));
        }

        (
            uint256 deficit,
            uint256 price,
            uint256 redeemableLiquidity,
            uint256 totalSupplied
        ) = venue.observeReserve(reserve, aToken);

        Observation memory o = Observation({
            blockNumber: uint64(block.number),
            deficit: deficit,
            price: price,
            redeemableLiquidity: redeemableLiquidity,
            totalSupplied: totalSupplied
        });

        obs.push(o);
        index = obs.length - 1;

        emit ObservationRecorded(
            reserve, o.blockNumber, o.deficit, o.price, o.redeemableLiquidity, o.totalSupplied
        );
    }

    function observationCount(address reserve) external view returns (uint256) {
        return _observations[reserve].length;
    }

    function observationAt(address reserve, uint256 index)
        external
        view
        returns (Observation memory)
    {
        return _observations[reserve][index];
    }

    // --- evaluation -----------------------------------------------------------------------

    function hashTerms(Terms calldata terms) public pure returns (bytes32) {
        return keccak256(abi.encode(terms));
    }

    /// @notice Evaluate a policy against the covered events and, if one held, make it claimable.
    /// @dev Permissionless. Whether a covered event occurred is a fact about chain history, and
    ///      establishing a fact is not a privileged action.
    function evaluate(uint256 policyId, Terms calldata terms)
        external
        returns (Trigger trigger)
    {
        ICoverPolicy.Policy memory p = policy.policies(policyId);

        if (p.termsHash != hashTerms(terms)) {
            revert TermsMismatch(policyId, p.termsHash, hashTerms(terms));
        }
        if (terms.reserve != p.reserve) revert TermsReserveMismatch();
        if (!policy.isCoverActive(policyId)) revert CoverNotActive(policyId);

        uint256 payout;
        (trigger, payout) = _assess(terms, p.coverAmount);
        if (trigger == Trigger.None) revert NoTriggerMet(policyId);

        claimAmount[policyId] = payout;
        triggerOf[policyId] = trigger;

        emit ClaimTriggered(policyId, trigger, payout);

        policy.markClaimable(policyId);
    }

    /// @notice Read-only evaluation, for the UI and for anyone checking the resolver's working.
    /// @dev Same code path as `evaluate`, so what a user is shown is what would actually settle.
    function assess(uint256 policyId, Terms calldata terms)
        external
        view
        returns (Trigger trigger, uint256 payout)
    {
        ICoverPolicy.Policy memory p = policy.policies(policyId);
        if (p.termsHash != hashTerms(terms)) {
            revert TermsMismatch(policyId, p.termsHash, hashTerms(terms));
        }
        return _assess(terms, p.coverAmount);
    }

    /// @dev A trigger holds only if every sampled observation inside the window satisfies it, the
    ///      samples span the whole window, the newest sample is fresh, and no adjacent samples are
    ///      farther apart than the policy allows. This is a bounded-cadence observation guarantee;
    ///      without the span and gap checks, `minSamples` could be clustered at the end of a window
    ///      and say nothing about the earlier blocks.
    function _assess(Terms calldata terms, uint256 coverAmount)
        internal
        view
        returns (Trigger, uint256)
    {
        if (terms.windowBlocks == 0 || terms.minSamples == 0 || terms.maxObservationGapBlocks == 0) {
            revert InvalidSamplingTerms();
        }

        Observation[] storage obs = _observations[terms.reserve];

        uint256 windowStart =
            block.number > terms.windowBlocks ? block.number - terms.windowBlocks : 0;

        AssessmentState memory state = AssessmentState({
            samples: 0,
            minDeficitBps: type(uint256).max,
            newestBlock: 0,
            previousBlock: 0,
            haveSample: false,
            windowCovered: false,
            deficitHeld: true,
            depegHeld: true,
            illiquidityHeld: true
        });

        // Walk backwards: the window is at the end of the array, so this touches only the recent
        // observations rather than the whole history. One observation just before the boundary is
        // admitted when it is within the permitted gap, so the condition is witnessed at the
        // window's leading edge rather than merely after it.
        for (uint256 i = obs.length; i > 0; i--) {
            Observation storage o = obs[i - 1];
            bool boundarySample = o.blockNumber <= windowStart;
            if (o.blockNumber < windowStart) {
                if (!state.haveSample || windowStart - o.blockNumber > terms.maxObservationGapBlocks) {
                    break;
                }
            }

            state.samples++;

            if (!state.haveSample) {
                state.newestBlock = o.blockNumber;
                state.haveSample = true;
            } else {
                if (state.previousBlock - o.blockNumber > terms.maxObservationGapBlocks) {
                    revert ObservationGapTooLarge(
                        state.previousBlock, o.blockNumber, terms.maxObservationGapBlocks
                    );
                }
            }
            state.previousBlock = o.blockNumber;

            uint256 deficitBps = _deficitBps(o);
            if (deficitBps < terms.deficitFloorBps || deficitBps == 0) state.deficitHeld = false;
            if (deficitBps < state.minDeficitBps) state.minDeficitBps = deficitBps;

            if (o.price >= terms.depegLowerBound) state.depegHeld = false;
            if (o.redeemableLiquidity >= (coverAmount * terms.liquidityFloorBps) / 10_000) {
                state.illiquidityHeld = false;
            }

            if (boundarySample) {
                state.windowCovered = true;
                break;
            }
        }

        // If the first retained sample is just after the boundary, the permitted cadence itself
        // covers that short leading interval. This is the normal case when the window starts
        // between two keeper observations.
        if (
            !state.windowCovered && state.haveSample && state.previousBlock >= windowStart
                && state.previousBlock - windowStart <= terms.maxObservationGapBlocks
        ) {
            state.windowCovered = true;
        }

        if (state.samples < terms.minSamples) {
            revert InsufficientSamples(state.samples, terms.minSamples);
        }
        if (!state.windowCovered) {
            revert ObservationWindowNotCovered(state.previousBlock, windowStart);
        }
        if (block.number - state.newestBlock > terms.maxObservationGapBlocks) {
            revert ObservationTooOld(
                state.newestBlock, block.number, terms.maxObservationGapBlocks
            );
        }

        // Settle on whichever covered event that actually held implies the largest loss, rather
        // than on a fixed order of severity. Since a deficit now pays in proportion to its size, a
        // fixed order would let a small-but-qualifying deficit mask a total redemption failure and
        // settle a full loss for a fraction of it.
        Trigger trigger = Trigger.None;
        uint256 payout = 0;

        if (state.deficitHeld) {
            trigger = Trigger.ReserveDeficit;
            payout = (coverAmount * state.minDeficitBps) / 10_000;
            if (payout > coverAmount) payout = coverAmount;
        }
        if (state.illiquidityHeld && coverAmount > payout) {
            trigger = Trigger.RedemptionFailure;
            payout = coverAmount;
        }
        if (state.depegHeld) {
            uint256 depeg = _depegPayout(terms, coverAmount);
            if (depeg > payout) {
                trigger = Trigger.OracleFailure;
                payout = depeg;
            }
        }

        // A qualifying condition that computes to a zero payout is not a claim. Marking a policy
        // Claimable and then settling it for nothing would consume the position and pay the holder
        // nothing at all.
        if (payout == 0) return (Trigger.None, 0);

        return (trigger, payout);
    }

    /// @notice A reserve's deficit as a share of the reserve, in basis points.
    ///
    /// @dev **Why a share and not an absolute figure, with the evidence.** A deficit is Aave's record
    ///      of bad debt, created whenever a liquidation leaves an account with zero collateral and
    ///      non-zero debt. That is routine, not exceptional, and it is only cleared by a permissioned
    ///      Umbrella call with no time constraint — so once nonzero it stays nonzero indefinitely.
    ///      Measured on Ethereum Aave V3 on 17 August 2026: **27 of 67 reserves carried a nonzero
    ///      deficit at the same moment**, including USDT at 0.830980 against 2,971,945,009 supplied
    ///      — 0.000000028% of the reserve — and cbBTC at literally one satoshi.
    ///
    ///      Treating any nonzero deficit as a total loss, as this contract first did, would have paid
    ///      full cover on every active policy against an implied depositor loss of roughly one part
    ///      in 3.6 billion. Worse, it would have looked correct until it fired: X Layer's reserves
    ///      all read zero today only because that market is young.
    ///
    ///      So the deficit is judged the way the depeg already is — as a proportion of the loss
    ///      actually suffered, with a floor that clears the noise. Below `deficitFloorBps` there is
    ///      no covered event; above it, the payout is the depositor's pro-rata share of the hole.
    ///
    ///      Returns zero when nothing is supplied, which is the only honest answer: there is no
    ///      reserve for a deficit to be a share of.
    function _deficitBps(Observation storage o) internal view returns (uint256) {
        if (o.totalSupplied == 0 || o.deficit == 0) return 0;
        return (o.deficit * 10_000) / o.totalSupplied;
    }

    /// @dev A depeg pays the shortfall against peg, not the whole position: the depositor still
    ///      holds an asset worth something, and paying full cover for a partial loss would be
    ///      overcompensation the pool's capital cannot honestly support. Uses the worst price
    ///      witnessed in the window, so a recovery mid-window does not inflate the payout.
    function _depegPayout(Terms calldata terms, uint256 coverAmount)
        internal
        view
        returns (uint256)
    {
        Observation[] storage obs = _observations[terms.reserve];
        uint256 windowStart =
            block.number > terms.windowBlocks ? block.number - terms.windowBlocks : 0;

        uint256 worst = PEG_PRICE;
        for (uint256 i = obs.length; i > 0; i--) {
            Observation storage o = obs[i - 1];
            bool boundarySample = o.blockNumber <= windowStart;
            if (o.blockNumber < windowStart
                && windowStart - o.blockNumber > terms.maxObservationGapBlocks) break;
            if (o.price < worst) worst = o.price;
            if (boundarySample) break;
        }

        if (worst >= PEG_PRICE) return 0;
        uint256 shortfall = ((PEG_PRICE - worst) * coverAmount) / PEG_PRICE;
        return shortfall > coverAmount ? coverAmount : shortfall;
    }

    // --- settlement -----------------------------------------------------------------------

    /// @notice Settle a claimable policy to whoever holds it.
    /// @dev Permissionless, and pays the holder rather than the caller: anyone may settle on
    ///      behalf of a holder who is offline, and there is nothing to gain by front-running it.
    ///      The policy contract enforces that only a Claimable policy can be paid, so this cannot
    ///      be called twice.
    function claim(uint256 policyId) external returns (uint256 amount) {
        amount = claimAmount[policyId];
        address holder = IERC721(address(policy)).ownerOf(policyId);

        // Effects before interactions: the policy is marked paid before capital moves.
        policy.markPaid(policyId, amount);
        pool.payClaim(policyId, holder, amount);

        emit ClaimSettled(policyId, holder, amount);
    }
}
