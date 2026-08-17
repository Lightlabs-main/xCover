// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @notice The pool's own guards, tested directly.
///
/// @dev **Why this file exists.** `CoverPool` was covered only by the two invariant suites. That
///      caught the properties they state, but a guard the fuzzer cannot reach in a *material* way is
///      invisible to them: `payClaim`'s cap on the payout was bounded in the handler to
///      `reserved + 1`, so the fuzzer could only ever overpay by one wei — far too small to move
///      solvency against capital in the millions. Deleting the cap entirely left both invariant
///      suites green, and nothing else in the suite referenced the error at all.
///
///      An invariant proves a property holds across the states the fuzzer visits. It is not a
///      substitute for asserting that a specific guard rejects a specific input.
contract CoverPoolTest is Test {
    CoverPool internal pool;
    TestUSDT internal asset;

    address internal vault = makeAddr("vault");
    address internal resolver = makeAddr("resolver");
    address internal provider = makeAddr("provider");
    address internal holder = makeAddr("holder");

    uint256 internal constant CAPITAL = 1_000_000e6;
    uint256 internal constant COVER = 10_000e6;
    uint256 internal constant POLICY_ID = 1;

    function setUp() public {
        asset = new TestUSDT();
        pool = new CoverPool(asset, address(this));

        pool.grantRole(pool.VAULT_ROLE(), vault);
        pool.grantRole(pool.CLAIM_ROLE(), resolver);

        asset.mint(provider, CAPITAL);
        vm.startPrank(provider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(CAPITAL);
        vm.stopPrank();

        vm.prank(vault);
        pool.reserveCover(POLICY_ID, COVER);
    }

    // --- payClaim -----------------------------------------------------------------------------

    /// @dev The cap that had no test. A resolver that computed too large a payout — the exact
    ///      failure mode the pro-rata deficit change introduced arithmetic for — must be stopped
    ///      here, because this is where the money actually moves.
    function test_PayoutCannotExceedTheCoverReserved() public {
        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.PayoutExceedsCover.selector, COVER + 1, COVER)
        );
        pool.payClaim(POLICY_ID, holder, COVER + 1);

        assertEq(asset.balanceOf(holder), 0, "an over-payout reached the holder");
        assertEq(pool.coverOf(POLICY_ID), COVER, "the reservation was consumed by a failed payout");
    }

    /// @dev A partial payout is the normal case now that a deficit pays pro-rata, so the release of
    ///      the unused remainder is asserted rather than assumed: the obligation ends in full even
    ///      though the payout did not use all of it.
    function test_PartialPayoutReleasesTheWholeReservation() public {
        uint256 payout = COVER / 4;

        vm.prank(resolver);
        pool.payClaim(POLICY_ID, holder, payout);

        assertEq(asset.balanceOf(holder), payout);
        assertEq(pool.coverOf(POLICY_ID), 0, "the reservation survived the claim");
        assertEq(pool.outstandingCover(), 0, "the unused cover stayed locked");
        assertEq(pool.capital(), CAPITAL - payout, "capital fell by more than was paid");
        assertGe(pool.capital(), pool.outstandingCover(), "insolvent after a partial payout");
    }

    /// @dev A payout of zero is not a claim. The resolver already refuses to mark one claimable,
    ///      but the pool must not depend on the resolver being correct about it.
    function test_PayingTwiceIsRejected() public {
        vm.prank(resolver);
        pool.payClaim(POLICY_ID, holder, COVER);

        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.NoCoverReserved.selector, POLICY_ID));
        pool.payClaim(POLICY_ID, holder, COVER);
    }

    function test_OnlyClaimRoleCanPay() public {
        vm.prank(vault);
        vm.expectRevert();
        pool.payClaim(POLICY_ID, holder, COVER);
    }

    // --- reserveCover -------------------------------------------------------------------------

    /// @dev The solvency chokepoint. Cover beyond free capital is refused, so the pool cannot
    ///      promise what it does not hold.
    function test_CannotReserveBeyondFreeCapital() public {
        uint256 free = pool.freeCapital();

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.InsufficientFreeCapital.selector, free + 1, free)
        );
        pool.reserveCover(2, free + 1);

        assertEq(pool.outstandingCover(), COVER, "a refused reservation still raised the total");
    }

    function test_CannotReserveTwiceAgainstOnePolicy() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.CoverAlreadyReserved.selector, POLICY_ID));
        pool.reserveCover(POLICY_ID, 1e6);
    }

    // --- withdrawCapital ----------------------------------------------------------------------

    /// @dev Capital behind active cover cannot leave. A provider who could withdraw it would be
    ///      unwinding someone else's protection.
    function test_CannotWithdrawCapitalLockedBehindCover() public {
        uint256 shares = pool.sharesOf(provider); // hoisted: an inner call would eat the prank

        vm.prank(provider);
        vm.expectRevert();
        pool.withdrawCapital(shares);

        assertEq(pool.capital(), CAPITAL, "locked capital left the pool");
    }

    function test_CanWithdrawUpToFreeCapital() public {
        uint256 shares = pool.sharesOf(provider);
        uint256 lockedShares = (shares * COVER) / CAPITAL;
        uint256 withdrawable = shares - lockedShares - 1; // -1 for the rounding-down dust

        vm.prank(provider);
        pool.withdrawCapital(withdrawable);

        assertGe(pool.capital(), pool.outstandingCover(), "insolvent after a withdrawal");
    }
}
