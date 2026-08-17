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
        vm.prank(vault);
        id = policy.mintPolicy(
            holder, address(asset), COVER, uint64(block.number) + 10_000, 1e21, bytes32(0), termsHash
        );
        vm.roll(policy.activeFromBlock(id));
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

    function test_SustainedDeficitTriggersFullCover() public {
        uint256 id = _mint();
        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES);

        ClaimResolver.Trigger t = _evaluate(id);

        assertEq(uint8(t), uint8(ClaimResolver.Trigger.ReserveDeficit));
        assertEq(resolver.claimAmount(id), COVER, "deficit did not pay full cover");
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Claimable));
    }

    /// @dev The whole point of windowed sampling. One clean reading inside the window means the
    ///      condition was not sustained, and a flash-loan-shaped blip must not pay.
    function test_ASingleCleanSampleDefeatsTheTrigger() public {
        uint256 id = _mint();

        venue.setReserve(1_000e6, 1_000e6);
        _observe(MIN_SAMPLES - 1);

        // One block where the deficit is absent.
        venue.setReserve(0, 0);
        _observe(1);

        venue.setReserve(1_000e6, 1_000e6);
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
