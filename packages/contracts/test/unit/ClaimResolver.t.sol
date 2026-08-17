// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {ClaimResolver} from "../../src/ClaimResolver.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";
import {StubVenue} from "../utils/StubVenue.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @notice Deterministic trigger evaluation, window sampling, and settlement.
/// @dev The rejection cases matter more than the acceptance case here. A resolver that pays on a
///      real trigger but also pays on a transient blip is worse than no resolver, because it
///      drains the capital that real claims depend on.
contract ClaimResolverTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    ClaimResolver internal resolver;
    StubVenue internal venue;
    TestUSDT internal asset;

    address internal aToken = makeAddr("aUSDT");
    address internal vault = makeAddr("vault");
    address internal provider = makeAddr("provider");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WAITING = 100;
    uint64 internal constant WINDOW = 50;
    uint64 internal constant MIN_SAMPLES = 5;
    uint256 internal constant COVER = 10_000e6;
    /// @dev 0.5% of the reserve unbacked. See ClaimResolver._deficitBps for the measurements.
    uint256 internal constant DEFICIT_FLOOR_BPS = 50;

    ClaimResolver.Terms internal terms;
    bytes32 internal termsHash;

    function setUp() public {
        asset = new TestUSDT();
        venue = new StubVenue(asset);

        pool = new CoverPool(asset, address(this));
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, 1_000_000e6, address(this));
        resolver = new ClaimResolver(
            ICoverPool(address(pool)),
            ICoverPolicy(address(policy)),
            IYieldVenue(address(venue)),
            address(this)
        );

        pool.grantRole(pool.VAULT_ROLE(), address(policy));
        pool.grantRole(pool.CLAIM_ROLE(), address(resolver));
        policy.grantRole(policy.VAULT_ROLE(), vault);
        policy.grantRole(policy.CLAIM_ROLE(), address(resolver));

        asset.mint(provider, 1_000_000e6);
        vm.startPrank(provider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(1_000_000e6);
        vm.stopPrank();

        terms = ClaimResolver.Terms({
            reserve: address(asset),
            aToken: aToken,
            windowBlocks: WINDOW,
            minSamples: MIN_SAMPLES,
            // Well clear of the ~10 bp of normal off-peg drift observed on chain: $0.97.
            depegLowerBound: 97_000_000,
            deficitFloorBps: DEFICIT_FLOOR_BPS,
            liquidityFloorBps: 10_000
        });
        termsHash = _hash(terms);

        // Healthy starting conditions: no deficit, at peg, ample redeemable liquidity.
        venue.setPrice(99_896_524);
        asset.mint(aToken, 5_000_000e6);

        vm.roll(1_000);
    }

    function _hash(ClaimResolver.Terms memory t) internal view returns (bytes32) {
        ClaimResolver.Terms[] memory arr = new ClaimResolver.Terms[](1);
        arr[0] = t;
        return this.hashTerms(arr);
    }

    function hashTerms(ClaimResolver.Terms[] calldata t) external view returns (bytes32) {
        return resolver.hashTerms(t[0]);
    }

    function _evaluate(uint256 id) internal returns (ClaimResolver.Trigger) {
        ClaimResolver.Terms[] memory arr = new ClaimResolver.Terms[](1);
        arr[0] = terms;
        return this.evaluate(id, arr);
    }

    function evaluate(uint256 id, ClaimResolver.Terms[] calldata t)
        external
        returns (ClaimResolver.Trigger)
    {
        return resolver.evaluate(id, t[0]);
    }

    function _mint() internal returns (uint256 id) {
        return _mintWithCover(COVER);
    }

    function _mintWithCover(uint256 cover) internal returns (uint256 id) {
        vm.prank(vault);
        id = policy.mintPolicy(
            holder, address(asset), cover, uint64(block.number) + 10_000, 1e21, bytes32(0), termsHash
        );
        vm.roll(policy.activeFromBlock(id));
    }

    /// @dev Set the venue to a deficit of exactly `bps` of the reserve, so a test states the share
    ///      the resolver actually judges rather than two absolute figures the reader must divide.
    function _setDeficitBps(uint256 bps) internal {
        uint256 supplied = 10_000_000e6;
        venue.setReserve((supplied * bps) / 10_000, supplied);
    }

    /// @dev Record `n` observations, one per block, as a keeper would.
    function _observe(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            resolver.recordObservation(address(asset), aToken);
            vm.roll(block.number + 1);
        }
    }

    // --- observation ----------------------------------------------------------------------

    /// @dev Anyone may establish what the chain said. If only a keeper could, a keeper who went
    ///      quiet would be able to deny every valid claim without ever calling a deny function.
    function test_ObservationIsPermissionless() public {
        vm.prank(stranger);
        resolver.recordObservation(address(asset), aToken);

        assertEq(resolver.observationCount(address(asset)), 1);
        ClaimResolver.Observation memory o = resolver.observationAt(address(asset), 0);
        assertEq(o.blockNumber, uint64(block.number));
        assertEq(o.price, 99_896_524);
        assertEq(o.redeemableLiquidity, 5_000_000e6);
        assertEq(o.deficit, 0);
    }

    function test_OneObservationPerBlock() public {
        resolver.recordObservation(address(asset), aToken);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimResolver.ObservationAlreadyRecorded.selector, uint64(block.number)
            )
        );
        resolver.recordObservation(address(asset), aToken);
    }

    /// @dev Observations are read from chain, never supplied by the caller, so a hostile recorder
    ///      can choose only *when* to record a true reading.
    function test_ObservationRecordsLiveStateNotCallerInput() public {
        venue.setReserve(500e6, 500e6);
        venue.setPrice(42_000_000);

        vm.prank(stranger);
        resolver.recordObservation(address(asset), aToken);

        ClaimResolver.Observation memory o = resolver.observationAt(address(asset), 0);
        assertEq(o.deficit, 500e6);
        assertEq(o.price, 42_000_000);
    }

    // --- reserve deficit ------------------------------------------------------------------

    /// @dev A wholly unbacked reserve — the deficit equals everything supplied — is the only case
    ///      that pays full cover, because it is the only case where the depositor lost everything.
    function test_TotallyUnbackedReservePaysFullCover() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.ReserveDeficit));
        assertEq(resolver.claimAmount(id), COVER, "a total loss did not pay full cover");
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Claimable));
    }

    /// @notice The measured resting state of Aave V3, which must not be a claim.
    /// @dev Ethereum Aave V3, 17 August 2026: USDT carried a deficit of 0.830980 against
    ///      2,971,945,009 supplied — 0.0000028 bp. 27 of 67 reserves were nonzero at that moment. The
    ///      first version of this contract would have paid full cover on every active policy against
    ///      an implied loss of one part in 3.6 billion, and it would have looked correct until it
    ///      fired, because X Layer's reserves read zero today only because that market is young.
    function test_AaveRestingDeficitIsNotAClaim() public {
        uint256 id = _mint();
        venue.setReserve(830_980, 2_971_945_009e6);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);

        assertEq(resolver.claimAmount(id), 0);
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Active));
    }

    /// @dev The floor is a boundary, so both sides of it are asserted. One basis point below it is
    ///      not a covered event; the floor itself is.
    function test_DeficitJustBelowTheFloorIsNotACoveredEvent() public {
        uint256 id = _mint();
        _setDeficitBps(DEFICIT_FLOOR_BPS - 1);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }

    function test_DeficitAtTheFloorTriggersAndPaysThatShare() public {
        uint256 id = _mint();
        _setDeficitBps(DEFICIT_FLOOR_BPS);
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.ReserveDeficit));
        // 50 bp of 10,000 of cover.
        assertEq(resolver.claimAmount(id), 50e6, "payout was not the deficit's share of cover");
    }

    /// @dev The point of the fix: a partial loss pays a partial claim. 5% of the reserve unbacked
    ///      pays 5% of cover, not all of it.
    function test_DeficitPaysProRataNotFullCover() public {
        uint256 id = _mint();
        _setDeficitBps(500);
        _observe(MIN_SAMPLES);

        _evaluate(id);

        assertEq(resolver.claimAmount(id), 500e6, "a 5% loss did not pay 5% of cover");
        assertLt(resolver.claimAmount(id), COVER, "a partial loss paid full cover");
    }

    /// @dev The trigger asserts the condition held *throughout* the window, so the payout is what
    ///      was true at every sample. A one-block spike cannot inflate it.
    function test_DeficitPayoutUsesTheSmallestShareInTheWindow() public {
        uint256 id = _mint();

        _setDeficitBps(1_000); // 10% at the worst
        _observe(2);
        _setDeficitBps(200); // partial recovery, still above the floor
        _observe(MIN_SAMPLES);

        _evaluate(id);

        assertEq(resolver.claimAmount(id), 200e6, "payout did not use the smallest share witnessed");
    }

    /// @dev No reserve means there is nothing for a deficit to be a share of. The honest answer is
    ///      no covered event, not a division by zero and not a full payout.
    function test_DeficitAgainstAnEmptyReserveIsNotAClaim() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 0);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }

    /// @dev A qualifying condition that rounds down to nothing is not a claim. Marking the policy
    ///      Claimable would consume the position and pay the holder zero — strictly worse for them
    ///      than leaving the cover in force.
    function test_QualifyingDeficitThatRoundsToZeroIsNotAClaim() public {
        // Cover so small that the floor's share of it is below one unit of the asset.
        uint256 id = _mintWithCover(100);
        _setDeficitBps(DEFICIT_FLOOR_BPS);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);

        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Active));
    }

    // --- which trigger settles ---------------------------------------------------------------

    /// @dev Triggers settle on the largest implied loss, not a fixed order of severity. Under a
    ///      fixed order a small qualifying deficit would mask a total redemption failure and settle
    ///      it for a fraction — here, 1% of cover instead of all of it.
    function test_RedemptionFailureBeatsASmallQualifyingDeficit() public {
        uint256 id = _mint();

        _setDeficitBps(100); // qualifies, but implies a 1% loss
        uint256 drain = asset.balanceOf(aToken) - 1_000e6;
        vm.prank(aToken);
        asset.transfer(address(0xdead), drain);
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.RedemptionFailure));
        assertEq(resolver.claimAmount(id), COVER, "the larger loss did not settle");
    }

    /// @dev And the same comparison in the other direction: a large deficit outranks a shallow
    ///      depeg, so severity order is genuinely computed rather than hardcoded.
    function test_LargeDeficitBeatsAShallowDepeg() public {
        uint256 id = _mint();

        _setDeficitBps(5_000); // 50% of the reserve unbacked -> 5,000 of cover
        venue.setPrice(96_000_000); // $0.96, below the bound -> 400 of cover
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.ReserveDeficit));
        assertEq(resolver.claimAmount(id), 5_000e6, "the larger loss did not settle");
    }

    function test_DeepDepegBeatsASmallQualifyingDeficit() public {
        uint256 id = _mint();

        _setDeficitBps(100); // 1% of cover
        venue.setPrice(90_000_000); // $0.90 -> 10% of cover
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.OracleFailure));
        assertEq(resolver.claimAmount(id), 1_000e6, "the larger loss did not settle");
    }

    /// @dev The whole point of windowed sampling. One reading inside the window that does not
    ///      qualify means the condition was not sustained, and a flash-loan-shaped blip must not
    ///      pay.
    ///
    ///      **The dip is deliberately sub-floor rather than zero.** With a zero-deficit block the
    ///      smallest share in the window is zero, so the payout rounds to nothing and the
    ///      zero-payout guard rejects the claim on its own — the sampling logic could be removed
    ///      entirely and this test would still pass. That is what it did after the payout became
    ///      pro-rata: it kept passing while proving nothing, having been mutation-checked against
    ///      the earlier full-cover code. A non-zero sub-floor dip forces the rejection to come from
    ///      the window rule itself.
    function test_ASingleNonQualifyingSampleDefeatsTheTrigger() public {
        uint256 id = _mint();

        _setDeficitBps(1_000);
        _observe(MIN_SAMPLES - 1);

        // One block where the deficit is real but below the floor.
        _setDeficitBps(DEFICIT_FLOOR_BPS - 1);
        _observe(1);

        _setDeficitBps(1_000);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }

    /// @dev And the same with the deficit fully absent for one block, which is the flash-loan
    ///      shape. Kept alongside the sub-floor case because the two reject by different routes.
    function test_ASingleCleanSampleDefeatsTheTrigger() public {
        uint256 id = _mint();

        _setDeficitBps(1_000);
        _observe(MIN_SAMPLES - 1);

        venue.setReserve(0, 0);
        _observe(1);

        _setDeficitBps(1_000);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }

    function test_TooFewSamplesIsNotATrigger() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimResolver.InsufficientSamples.selector, MIN_SAMPLES - 1, MIN_SAMPLES
            )
        );
        _evaluate(id);
    }

    /// @dev Observations older than the window do not count, so a deficit that was resolved long
    ///      ago cannot be replayed into a claim today.
    function test_ObservationsOutsideTheWindowAreIgnored() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        vm.roll(block.number + WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ClaimResolver.InsufficientSamples.selector, 0, MIN_SAMPLES)
        );
        _evaluate(id);
    }

    // --- oracle failure -------------------------------------------------------------------

    /// @dev Normal conditions sit ~10 bp off peg. A threshold that fired on that would pay out
    ///      constantly, so the bound is set well outside it and this asserts the gap holds.
    function test_NormalOffPegDriftDoesNotTrigger() public {
        uint256 id = _mint();
        venue.setPrice(99_896_524); // the live mainnet reading
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }

    function test_SustainedDepegPaysTheShortfallNotFullCover() public {
        uint256 id = _mint();
        venue.setPrice(90_000_000); // $0.90
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.OracleFailure));
        // 10% shortfall against peg on 10,000 of cover.
        assertEq(resolver.claimAmount(id), 1_000e6, "depeg payout was not the shortfall");
    }

    /// @dev The worst price in the window sets the payout, so a partial recovery before the claim
    ///      is filed does not reduce what the holder actually lost.
    function test_DepegPayoutUsesTheWorstPriceInTheWindow() public {
        uint256 id = _mint();

        venue.setPrice(80_000_000); // $0.80 at the bottom
        _observe(2);
        venue.setPrice(95_000_000); // partial recovery, still below bound
        _observe(MIN_SAMPLES);

        _evaluate(id);
        assertEq(resolver.claimAmount(id), 2_000e6, "payout did not use the worst price");
    }

    // --- redemption failure ---------------------------------------------------------------

    function test_SustainedIlliquidityTriggersFullCover() public {
        uint256 id = _mint();

        // Redeemable liquidity falls below the policy's cover. The drain amount is computed
        // before the prank: an external call in the argument list would consume it.
        uint256 drain = asset.balanceOf(aToken) - 1_000e6;
        vm.prank(aToken);
        asset.transfer(address(0xdead), drain);
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.RedemptionFailure));
        assertEq(resolver.claimAmount(id), COVER);
    }

    // --- terms ----------------------------------------------------------------------------

    /// @dev Thresholds cannot be renegotiated after a loss. Supplying friendlier terms than the
    ///      ones fixed at mint is rejected on the hash, not argued about.
    function test_RejectsTermsThatDoNotMatchThePolicy() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        ClaimResolver.Terms memory friendly = terms;
        friendly.minSamples = 1;
        ClaimResolver.Terms[] memory arr = new ClaimResolver.Terms[](1);
        arr[0] = friendly;

        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimResolver.TermsMismatch.selector, id, termsHash, _hash(friendly)
            )
        );
        this.evaluate(id, arr);
    }

    // --- cover status ---------------------------------------------------------------------

    function test_CannotEvaluateInsideTheWaitingPeriod() public {
        vm.prank(vault);
        uint256 id = policy.mintPolicy(
            holder, address(asset), COVER, uint64(block.number) + 10_000, 1e21, bytes32(0), termsHash
        );

        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.CoverNotActive.selector, id));
        _evaluate(id);
    }

    function test_CannotEvaluateAnExpiredPolicy() public {
        uint256 id = _mint();
        vm.roll(policy.policies(id).endBlock + 1);

        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.CoverNotActive.selector, id));
        _evaluate(id);
    }

    // --- settlement -----------------------------------------------------------------------

    function test_ClaimPaysTheHolderAndClosesThePolicy() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);

        uint256 capitalBefore = pool.capital();

        vm.prank(stranger); // permissionless: anyone may settle on the holder's behalf
        uint256 paid = resolver.claim(id);

        assertEq(paid, COVER);
        assertEq(asset.balanceOf(holder), COVER, "payout did not reach the holder");
        assertEq(asset.balanceOf(stranger), 0, "caller was paid instead of the holder");
        assertEq(pool.capital(), capitalBefore - COVER);
        assertEq(pool.outstandingCover(), 0);
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Paid));
        assertGe(pool.capital(), pool.outstandingCover(), "insolvent after settlement");
    }

    /// @dev The payout follows the token, not the address that bought it.
    function test_ClaimPaysTheCurrentHolderAfterTransfer() public {
        uint256 id = _mint();
        address buyer = makeAddr("buyer");
        vm.prank(holder);
        policy.transferFrom(holder, buyer, id);

        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);
        resolver.claim(id);

        assertEq(asset.balanceOf(buyer), COVER);
        assertEq(asset.balanceOf(holder), 0);
    }

    function test_CannotClaimTwice() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);
        resolver.claim(id);

        vm.expectRevert();
        resolver.claim(id);
    }

    function test_CannotClaimWithoutEvaluation() public {
        uint256 id = _mint();

        vm.expectRevert();
        resolver.claim(id);
    }

    // --- no override, in either direction -------------------------------------------------

    /// @dev The deployer holds `DEFAULT_ADMIN_ROLE` here and it buys nothing: there is no
    ///      function that approves an untriggered claim. Roles cannot grant what does not exist.
    function test_AdminCannotForceATriggerThatDidNotHold() public {
        uint256 id = _mint();
        _observe(MIN_SAMPLES); // healthy conditions throughout

        assertTrue(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), address(this)));

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);

        assertEq(resolver.claimAmount(id), 0);
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Active));

        // Nor can the admin reach the policy contract directly: CLAIM_ROLE there is the
        // resolver's, and the admin does not hold it.
        vm.expectRevert();
        policy.markClaimable(id);
    }

    /// @dev And the reverse: once a trigger has held, no role can stop the settlement.
    function test_AdminCannotBlockATriggeredClaim() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);

        // Every lever the admin actually has, pulled at once.
        pool.pauseIssuance();
        resolver.revokeRole(resolver.KEEPER_ROLE(), address(this));

        vm.prank(stranger);
        resolver.claim(id);

        assertEq(asset.balanceOf(holder), COVER, "an admin blocked a triggered claim");
    }

    /// @dev Pausing halts issuance. It must not reach a claim that has already triggered.
    function test_PausedIssuanceDoesNotBlockSettlement() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);

        pool.pauseIssuance();
        resolver.claim(id);

        assertEq(asset.balanceOf(holder), COVER, "a pause blocked a triggered claim");
    }
}
