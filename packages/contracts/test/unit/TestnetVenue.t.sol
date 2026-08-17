// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestnetVenue} from "../../src/venues/TestnetVenue.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The custody-only testnet venue, including the assertions that keep it honest about
///         what it is.
contract TestnetVenueTest is Test {
    TestnetVenue internal venue;
    TestUSDT internal asset;

    address internal vault = makeAddr("vault");
    address internal user = makeAddr("user");

    function setUp() public {
        asset = new TestUSDT();
        venue = new TestnetVenue(IERC20(address(asset)), address(this));
        venue.grantRole(venue.VAULT_ROLE(), vault);

        asset.mint(vault, 1_000_000e6);
        vm.prank(vault);
        asset.approve(address(venue), type(uint256).max);
    }

    /// @dev The single most important property of this contract: it does not claim to be
    ///      something it is not. A UI reading `hasYieldSource()` cannot show an APY here.
    function test_DeclaresItselfAsHavingNoYieldSource() public view {
        assertFalse(venue.hasYieldSource(), "custody-only venue claims a yield source");
        assertEq(venue.venueName(), "custody-only/xlayer-testnet");
    }

    function test_DepositCustodiesOneForOne() public {
        vm.prank(vault);
        uint256 supplied = venue.deposit(100_000e6);

        assertEq(supplied, 100_000e6);
        assertEq(venue.totalAssets(), 100_000e6);
        assertEq(asset.balanceOf(address(venue)), 100_000e6);
    }

    /// @dev No yield means no yield: time passing changes nothing, and the contract does not
    ///      invent a number to fill the gap.
    function test_NoYieldAccruesOverTime() public {
        vm.prank(vault);
        venue.deposit(100_000e6);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);

        assertEq(venue.totalAssets(), 100_000e6, "custody-only venue invented yield");
    }

    function test_WithdrawReturnsExactlyWhatWasDeposited() public {
        vm.prank(vault);
        venue.deposit(100_000e6);

        vm.prank(vault);
        uint256 redeemed = venue.withdraw(40_000e6, user);

        assertEq(redeemed, 40_000e6);
        assertEq(asset.balanceOf(user), 40_000e6);
        assertEq(venue.totalAssets(), 60_000e6);
    }

    function test_WithdrawBeyondDepositsReverts() public {
        vm.prank(vault);
        venue.deposit(100_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IYieldVenue.InsufficientVenueLiquidity.selector, 100_001e6, 100_000e6
            )
        );
        vm.prank(vault);
        venue.withdraw(100_001e6, user);
    }

    /// @dev A donation to the venue must not become withdrawable: it was never deposited, and
    ///      counting it would let one user's accident fund another user's withdrawal.
    function test_DonatedAssetsAreNotCountedAsDeposits() public {
        vm.prank(vault);
        venue.deposit(100_000e6);

        asset.mint(address(venue), 50_000e6);

        assertEq(venue.totalAssets(), 100_000e6, "donation was credited as a deposit");
    }

    function test_ZeroAmountsRejected() public {
        vm.expectRevert(IYieldVenue.ZeroAmount.selector);
        vm.prank(vault);
        venue.deposit(0);

        vm.expectRevert(IYieldVenue.ZeroAmount.selector);
        vm.prank(vault);
        venue.withdraw(0, user);
    }

    function test_OnlyVaultCanDepositOrWithdraw() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, venue.VAULT_ROLE()
            )
        );
        vm.prank(user);
        venue.deposit(1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, venue.VAULT_ROLE()
            )
        );
        vm.prank(user);
        venue.withdraw(1_000e6, user);
    }

    // --- the readings ClaimResolver samples ------------------------------------------------

    /// @dev A quiet venue must read as quiet. If the resting state were anything other than
    ///      "no deficit, at peg", every policy would sit one window away from a payout.
    function test_ObserveReserveRestsAtNoDeficitAndPeg() public {
        vm.prank(vault);
        venue.deposit(50_000e6);

        (uint256 deficit, uint256 price, uint256 liquidity,) =
            venue.observeReserve(address(asset), address(0));

        assertEq(deficit, 0, "a venue that has lost nothing reports a deficit");
        assertEq(price, 1e8, "resting price is not peg");
        assertEq(liquidity, 50_000e6, "redeemable liquidity is not what is held");
    }

    function test_ObserveReserveRejectsAnUnknownReserve() public {
        vm.expectRevert(
            abi.encodeWithSelector(TestnetVenue.UnknownReserve.selector, address(0xBEEF))
        );
        venue.observeReserve(address(0xBEEF), address(0));
    }

    // --- the judge trigger (SPEC 3.5) -----------------------------------------------------

    /// @dev The deficit has to be real, not a counter. If `induceDeficit` only wrote a number,
    ///      the payout a judge watches would be settling against an imaginary loss, and the
    ///      testnet demo would be exactly the fabricated demo the rules forbid.
    function test_InduceDeficitActuallyRemovesTheAssets() public {
        vm.prank(vault);
        venue.deposit(50_000e6);

        venue.induceDeficit(address(asset), 20_000e6);

        (uint256 deficit,, uint256 liquidity,) = venue.observeReserve(address(asset), address(0));
        assertEq(deficit, 20_000e6, "deficit not recorded");
        assertEq(liquidity, 30_000e6, "assets did not actually leave the venue");
        assertEq(asset.balanceOf(venue.DEFICIT_SINK()), 20_000e6, "assets were not written off");

        // Obligations stand at the full amount. That gap is what a deficit *is*.
        assertEq(venue.deposited(), 50_000e6, "a deficit quietly reduced what depositors are owed");
    }

    /// @dev The venue cannot invent a shortfall larger than the assets it holds; a deficit is a
    ///      loss of real value, and there is only so much real value here to lose.
    function test_InduceDeficitCannotExceedHoldings() public {
        vm.prank(vault);
        venue.deposit(1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetVenue.DeficitExceedsHoldings.selector, 1_001e6, 1_000e6
            )
        );
        venue.induceDeficit(address(asset), 1_001e6);
    }

    /// @dev A real deficit must make redemption genuinely fail. If withdrawals still succeeded
    ///      after the assets were gone, the deficit would not be modelling anything.
    function test_RedemptionFailsOnceAssetsAreGone() public {
        vm.prank(vault);
        venue.deposit(50_000e6);
        venue.induceDeficit(address(asset), 50_000e6);

        vm.prank(vault);
        vm.expectRevert(); // ERC20 insufficient balance: the assets are not there to return
        venue.withdraw(50_000e6, user);
    }

    function test_ReportedPriceMovesForTheDepegTrigger() public {
        venue.setReportedPrice(address(asset), 90_000_000);
        (, uint256 price,,) = venue.observeReserve(address(asset), address(0));
        assertEq(price, 90_000_000);
    }

    /// @dev The trigger surface is permissioned even on testnet. Anyone able to induce a deficit
    ///      could trigger every live policy at will, which would make the testnet lifecycle
    ///      evidence worthless rather than merely unrealistic.
    function test_OnlyDemoRoleCanMoveTheTriggers() public {
        vm.prank(vault);
        venue.deposit(1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, venue.DEMO_ROLE()
            )
        );
        vm.prank(user);
        venue.induceDeficit(address(asset), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, venue.DEMO_ROLE()
            )
        );
        vm.prank(user);
        venue.setReportedPrice(address(asset), 1);
    }
}
