// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The §4.2 lifecycle: every transition, every gate, and the reservation accounting that
///         has to move with them.
contract CoverPolicyTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    TestUSDT internal asset;

    address internal vault = makeAddr("vault");
    address internal resolver = makeAddr("resolver");
    address internal provider = makeAddr("provider");
    address internal holder = makeAddr("holder");
    address internal reserve = makeAddr("reserve");

    uint64 internal constant WAITING = 100;
    uint256 internal constant DAILY_CAP = 500_000e6;
    uint64 internal constant TERM = 10_000;

    function setUp() public {
        asset = new TestUSDT();
        pool = new CoverPool(asset, address(this));
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, DAILY_CAP, address(this));

        pool.grantRole(pool.VAULT_ROLE(), address(policy));
        pool.grantRole(pool.CLAIM_ROLE(), resolver);
        policy.grantRole(policy.VAULT_ROLE(), vault);
        policy.grantRole(policy.CLAIM_ROLE(), resolver);

        asset.mint(provider, 1_000_000e6);
        vm.startPrank(provider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(1_000_000e6);
        vm.stopPrank();

        // Start clear of block zero so waiting-period arithmetic is meaningful.
        vm.roll(1_000);
    }

    function _mint(uint256 coverAmount) internal returns (uint256) {
        vm.prank(vault);
        return policy.mintPolicy(
            holder,
            reserve,
            coverAmount,
            uint64(block.number) + TERM,
            1e21,
            keccak256("quote"),
            keccak256("terms")
        );
    }

    // --- issuance -------------------------------------------------------------------------

    function test_MintLocksCapitalInSameTransaction() public {
        uint256 id = _mint(10_000e6);

        assertEq(policy.ownerOf(id), holder);
        assertEq(pool.coverOf(id), 10_000e6, "policy exists without capital behind it");
        assertEq(pool.outstandingCover(), 10_000e6);
        assertEq(pool.freeCapital(), 990_000e6);

        ICoverPolicy.Policy memory p = policy.policies(id);
        assertEq(uint8(p.state), uint8(ICoverPolicy.PolicyState.Active));
        assertEq(p.coverAmount, 10_000e6);
    }

    /// @dev The daily cap binds well below total capital, so free capital has to be drawn down
    ///      across several reserves before the solvency bound is the one that actually binds.
    ///      That ordering is the point: the cap is a per-reserve control, solvency is absolute.
    function test_MintRevertsWhenPoolCannotBackTheCover() public {
        address reserveB = makeAddr("reserveB");
        address reserveC = makeAddr("reserveC");

        vm.startPrank(vault);
        policy.mintPolicy(
            holder, reserve, 500_000e6, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );
        policy.mintPolicy(
            holder, reserveB, 300_000e6, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );
        vm.stopPrank();

        assertEq(pool.freeCapital(), 200_000e6);

        // Within the daily cap for a fresh reserve, but beyond what the pool can back.
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPool.InsufficientFreeCapital.selector, 300_000e6, 200_000e6
            )
        );
        vm.prank(vault);
        policy.mintPolicy(
            holder, reserveC, 300_000e6, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );

        // Nothing partial was created: the obligation total is unchanged.
        assertEq(pool.outstandingCover(), 800_000e6);
    }

    function test_MintRevertsOnZeroCover() public {
        vm.expectRevert(ICoverPolicy.ZeroAmount.selector);
        vm.prank(vault);
        policy.mintPolicy(
            holder, reserve, 0, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );
    }

    /// @dev A term ending inside the waiting period would be paid for and never provide cover.
    function test_MintRevertsWhenTermEndsInsideWaitingPeriod() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.InvalidTerm.selector, uint64(block.number), uint64(block.number) + WAITING
            )
        );
        vm.prank(vault);
        policy.mintPolicy(
            holder,
            reserve,
            1_000e6,
            uint64(block.number) + WAITING,
            1e21,
            bytes32(0),
            bytes32(0)
        );
    }

    function test_OnlyVaultCanMint() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                holder,
                policy.VAULT_ROLE()
            )
        );
        vm.prank(holder);
        policy.mintPolicy(
            holder, reserve, 1_000e6, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );
    }

    // --- adverse selection controls -------------------------------------------------------

    function test_CoverIsNotActiveDuringWaitingPeriod() public {
        uint256 id = _mint(10_000e6);

        assertFalse(policy.isCoverActive(id), "cover live before the waiting period elapsed");
        vm.roll(block.number + WAITING - 1);
        assertFalse(policy.isCoverActive(id));
        vm.roll(block.number + 1);
        assertTrue(policy.isCoverActive(id), "cover never activated");
    }

    function test_CannotBecomeClaimableDuringWaitingPeriod() public {
        uint256 id = _mint(10_000e6);
        uint64 activeFrom = policy.activeFromBlock(id);

        vm.expectRevert(
            abi.encodeWithSelector(ICoverPolicy.WaitingPeriodActive.selector, id, activeFrom)
        );
        vm.prank(resolver);
        policy.markClaimable(id);

        vm.roll(activeFrom);
        vm.prank(resolver);
        policy.markClaimable(id);
        assertEq(
            uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Claimable)
        );
    }

    function test_DailyCapBoundsNewCoverPerReserve() public {
        _mint(DAILY_CAP - 1_000e6);
        assertEq(policy.remainingDailyCapacity(reserve), 1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.DailyCapExceeded.selector, reserve, 1_001e6, 1_000e6
            )
        );
        vm.prank(vault);
        policy.mintPolicy(
            holder, reserve, 1_001e6, uint64(block.number) + TERM, 1e21, bytes32(0), bytes32(0)
        );

        // The cap is per day: the next day starts fresh.
        vm.warp(block.timestamp + 1 days);
        assertEq(policy.remainingDailyCapacity(reserve), DAILY_CAP);
        _mint(1_001e6);
    }

    function test_DailyCapIsPerReserve() public {
        _mint(DAILY_CAP);
        assertEq(policy.remainingDailyCapacity(reserve), 0);
        assertEq(policy.remainingDailyCapacity(address(0xBEEF)), DAILY_CAP);
    }

    // --- terminal transitions -------------------------------------------------------------

    function test_ExpiryReleasesCapital() public {
        uint256 id = _mint(10_000e6);
        vm.roll(block.number + TERM + 1);

        policy.expire(id);

        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Expired));
        assertEq(pool.coverOf(id), 0, "capital still locked behind an expired policy");
        assertEq(pool.outstandingCover(), 0);
        assertEq(pool.freeCapital(), 1_000_000e6);
    }

    function test_ExpiryRevertsBeforeTermEnds() public {
        uint256 id = _mint(10_000e6);
        uint64 endBlock = policy.policies(id).endBlock;

        vm.expectRevert(abi.encodeWithSelector(ICoverPolicy.NotExpired.selector, id, endBlock));
        policy.expire(id);
    }

    /// @dev Expiry is a fact about the block number, not a decision. Nobody's cooperation is
    ///      needed to free capital that is no longer at risk.
    function test_ExpiryIsPermissionless() public {
        uint256 id = _mint(10_000e6);
        vm.roll(block.number + TERM + 1);

        vm.prank(address(0xDEAD));
        policy.expire(id);

        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Expired));
    }

    function test_CancelReleasesCapital() public {
        uint256 id = _mint(10_000e6);

        vm.prank(vault);
        policy.cancel(id);

        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Cancelled));
        assertEq(pool.coverOf(id), 0);
        assertEq(pool.outstandingCover(), 0);
    }

    function test_ClaimPathSettlesFromPoolCapital() public {
        uint256 id = _mint(10_000e6);
        vm.roll(policy.activeFromBlock(id));

        vm.prank(resolver);
        policy.markClaimable(id);

        vm.startPrank(resolver);
        pool.payClaim(id, holder, 10_000e6);
        policy.markPaid(id, 10_000e6);
        vm.stopPrank();

        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Paid));
        assertEq(asset.balanceOf(holder), 10_000e6, "holder was not paid");
        assertEq(pool.capital(), 990_000e6);
        assertEq(pool.outstandingCover(), 0);
        assertGe(pool.capital(), pool.outstandingCover(), "insolvent after settlement");
    }

    // --- terminal states are terminal -----------------------------------------------------

    function test_CannotExpireTwice() public {
        uint256 id = _mint(10_000e6);
        vm.roll(block.number + TERM + 1);
        policy.expire(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.InvalidState.selector,
                id,
                ICoverPolicy.PolicyState.Expired,
                ICoverPolicy.PolicyState.Active
            )
        );
        policy.expire(id);
    }

    function test_CannotCancelAnExpiredPolicy() public {
        uint256 id = _mint(10_000e6);
        vm.roll(block.number + TERM + 1);
        policy.expire(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.InvalidState.selector,
                id,
                ICoverPolicy.PolicyState.Expired,
                ICoverPolicy.PolicyState.Active
            )
        );
        vm.prank(vault);
        policy.cancel(id);
    }

    function test_CannotClaimACancelledPolicy() public {
        uint256 id = _mint(10_000e6);
        vm.prank(vault);
        policy.cancel(id);
        vm.roll(policy.activeFromBlock(id));

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.InvalidState.selector,
                id,
                ICoverPolicy.PolicyState.Cancelled,
                ICoverPolicy.PolicyState.Active
            )
        );
        vm.prank(resolver);
        policy.markClaimable(id);
    }

    function test_CannotMarkPaidWithoutBeingClaimable() public {
        uint256 id = _mint(10_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPolicy.InvalidState.selector,
                id,
                ICoverPolicy.PolicyState.Active,
                ICoverPolicy.PolicyState.Claimable
            )
        );
        vm.prank(resolver);
        policy.markPaid(id, 10_000e6);
    }

    function test_UnknownPolicyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPolicy.UnknownPolicy.selector, 999));
        policy.policies(999);

        vm.expectRevert(abi.encodeWithSelector(ICoverPolicy.UnknownPolicy.selector, 999));
        policy.expire(999);
    }

    // --- access control -------------------------------------------------------------------

    function test_OnlyResolverCanMarkClaimable() public {
        uint256 id = _mint(10_000e6);
        vm.roll(policy.activeFromBlock(id));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                vault,
                policy.CLAIM_ROLE()
            )
        );
        vm.prank(vault);
        policy.markClaimable(id);
    }

    function test_OnlyVaultCanCancel() public {
        uint256 id = _mint(10_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                holder,
                policy.VAULT_ROLE()
            )
        );
        vm.prank(holder);
        policy.cancel(id);
    }

    /// @dev The policy is a transferable position; the obligation follows the token.
    function test_PolicyIsTransferableAndPaysTheNewHolder() public {
        uint256 id = _mint(10_000e6);
        address buyer = address(0xBEEF);

        vm.prank(holder);
        policy.transferFrom(holder, buyer, id);
        assertEq(policy.ownerOf(id), buyer);

        vm.roll(policy.activeFromBlock(id));
        vm.startPrank(resolver);
        policy.markClaimable(id);
        pool.payClaim(id, policy.ownerOf(id), 10_000e6);
        policy.markPaid(id, 10_000e6);
        vm.stopPrank();

        assertEq(asset.balanceOf(buyer), 10_000e6);
    }
}
