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
}
