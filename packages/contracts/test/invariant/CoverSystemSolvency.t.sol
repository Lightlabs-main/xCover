// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {CoverSystemHandler} from "./CoverSystemHandler.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @title CoverSystemSolvency
/// @notice The solvency invariant across the real issuance path: obligations are created only by
///         minting a policy and released only by a lifecycle transition.
///
/// @dev `CoverPoolSolvency` proves the pool's arithmetic. This proves the property survives the
///      seam between the two contracts, and adds the property that binds them together:
///
///          a policy holds a pool reservation if and only if it is Active or Claimable
///
///      That is what makes the solvency number meaningful rather than merely self-consistent. A
///      pool could satisfy `capital >= outstandingCover` while locking capital behind a policy
///      that ended months ago, or — far worse — while a live policy holds no reservation at all
///      and would find nothing there on a claim.
contract CoverSystemSolvencyTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    TestUSDT internal asset;
    CoverSystemHandler internal handler;

    uint64 internal constant WAITING = 100;
    uint256 internal constant DAILY_CAP = 1_000_000e6;

    function setUp() public {
        asset = new TestUSDT();
        pool = new CoverPool(asset, address(this));
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, DAILY_CAP, address(this));
        handler = new CoverSystemHandler(pool, policy, asset);

        // CoverPolicy is the only holder of VAULT_ROLE on the pool: obligations can be created
        // exclusively by minting a policy, which is the property under test.
        pool.grantRole(pool.VAULT_ROLE(), address(policy));
        pool.grantRole(pool.CLAIM_ROLE(), address(handler));
        pool.grantRole(pool.ADMIN_ROLE(), address(handler));

        // The handler stands in for xCoverVault (issuance) and ClaimResolver (settlement).
        policy.grantRole(policy.VAULT_ROLE(), address(handler));
        policy.grantRole(policy.CLAIM_ROLE(), address(handler));

        // Seed the pool with capital from a provider outside the handler's actor set. A pool that
        // starts empty spends the early depth of every sequence rejecting mints for lack of
        // capital, which leaves the lifecycle paths — where the interesting bugs are — untested.
        address seedProvider = makeAddr("seedProvider");
        asset.mint(seedProvider, 2_000_000e6);
        vm.startPrank(seedProvider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(2_000_000e6);
        vm.stopPrank();

        vm.roll(1_000);
        targetContract(address(handler));
    }

    /// @notice Cover promised never exceeds capital held.
    function invariant_CapitalCoversOutstanding() public view {
        assertGe(
            pool.capital(),
            pool.outstandingCover(),
            "insolvent: outstanding cover exceeds capital"
        );
    }

    /// @notice Internal capital accounting is backed by assets the pool actually holds.
    function invariant_BalanceBacksCapital() public view {
        assertGe(
            asset.balanceOf(address(pool)),
            pool.capital(),
            "capital accounting exceeds the assets held"
        );
    }

    /// @notice A policy holds a reservation exactly while it is live, and never afterwards.
    function invariant_ReservationsTrackPolicyState() public view {
        uint256 sum;
        uint256 n = handler.policyCount();

        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.policyIds(i);
            ICoverPolicy.Policy memory p = policy.policies(id);
            uint256 reserved = pool.coverOf(id);
            sum += reserved;

            if (p.state == ICoverPolicy.PolicyState.Active
                || p.state == ICoverPolicy.PolicyState.Claimable) {
                assertEq(reserved, p.coverAmount, "live policy is not fully backed");
            } else {
                assertEq(reserved, 0, "capital still locked behind a terminated policy");
            }
        }

        assertEq(sum, pool.outstandingCover(), "outstanding cover drifted from its policy sum");
    }

    /// @notice Report the call distribution so an unproductive run is visible rather than passing
    ///         as proof. A sequence that never minted a policy has not tested anything.
    function invariant_CallSummary() public view {
        console2.log("policies minted", handler.policyCount());
        console2.log("mintPolicy     ", handler.calls("mintPolicy"));
        console2.log("expirePolicy   ", handler.calls("expirePolicy"));
        console2.log("cancelPolicy   ", handler.calls("cancelPolicy"));
        console2.log("markClaimable  ", handler.calls("markClaimable"));
        console2.log("settleClaim    ", handler.calls("settleClaim"));
        console2.log("depositCapital ", handler.calls("depositCapital"));
        console2.log("withdrawCapital", handler.calls("withdrawCapital"));
        console2.log("advance        ", handler.calls("advance"));
        console2.log("advanceDay     ", handler.calls("advanceDay"));
    }
}
