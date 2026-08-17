// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPoolHandler} from "./CoverPoolHandler.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @title CoverPoolSolvency
/// @notice The solvency invariant. SPEC §1.2.4: cover sold must never exceed capital held — not
///         "usually", not "within tolerance", never, under any reachable sequence of calls.
///
/// @dev Three properties, checked after every call of every fuzzed sequence:
///
///      1. `capital >= outstandingCover`
///         The promise is backed. This is the product.
///
///      2. `asset.balanceOf(pool) >= capital`
///         The accounting is backed by real tokens. Property 1 alone is blind to an internal
///         counter drifting away from the assets actually held — an unaccounted transfer out, a
///         claim that decrements one side and not the other. This is the property that sees it.
///
///      3. `sum(coverOf(p)) == outstandingCover` over every policy ever touched
///         The obligation total has not drifted from the sum of its parts. Recomputed from
///         scratch rather than tracked incrementally, so it cannot inherit the pool's own bug.
///
///      This test must never be cut.
contract CoverPoolSolvencyTest is Test {
    CoverPool internal pool;
    TestUSDT internal asset;
    CoverPoolHandler internal handler;

    function setUp() public {
        asset = new TestUSDT();
        pool = new CoverPool(asset, address(this));

        handler = new CoverPoolHandler(pool, asset);

        // The handler stands in for the roles that would be held by xCoverVault (issuance) and
        // ClaimResolver (settlement), so that fuzzed sequences can exercise both against one pool.
        pool.grantRole(pool.VAULT_ROLE(), address(handler));
        pool.grantRole(pool.CLAIM_ROLE(), address(handler));
        pool.grantRole(pool.ADMIN_ROLE(), address(handler));

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

    /// @notice `outstandingCover` equals the sum of the per-policy obligations behind it.
    function invariant_OutstandingCoverMatchesPolicySum() public view {
        uint256 sum;
        uint256 n = handler.touchedPoliciesLength();
        for (uint256 i = 0; i < n; i++) {
            sum += pool.coverOf(handler.touchedPolicies(i));
        }
        assertEq(sum, pool.outstandingCover(), "outstanding cover drifted from its policy sum");
    }

    /// @notice Report the call distribution so an unproductive run is visible rather than passing
    ///         as proof. A sequence that never reserved cover has not tested solvency.
    function invariant_CallSummary() public view {
        console2.log("depositCapital ", handler.calls("depositCapital"));
        console2.log("withdrawCapital", handler.calls("withdrawCapital"));
        console2.log("reserveCover   ", handler.calls("reserveCover"));
        console2.log("releaseCover   ", handler.calls("releaseCover"));
        console2.log("payClaim       ", handler.calls("payClaim"));
        console2.log("accruePremium  ", handler.calls("accruePremium"));
        console2.log("donate         ", handler.calls("donate"));
        console2.log("togglePause    ", handler.calls("togglePause"));
    }
}
