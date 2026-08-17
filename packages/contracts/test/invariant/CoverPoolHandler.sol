// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @notice Drives `CoverPool` through arbitrary sequences of every state-changing call.
/// @dev The invariant runner calls these functions in fuzzed order with fuzzed arguments. Inputs
///      are bounded rather than filtered so that sequences stay productive: an unbounded fuzzer
///      spends most of its depth on calls that revert on the first argument check and never
///      reaches the accounting paths where a solvency bug would actually live.
///
///      Reverts are tolerated (`fail_on_revert = false`) because rejecting an unsafe call is
///      correct behaviour under test — a `reserveCover` that would breach the invariant is
///      *supposed* to revert, and that path must stay reachable by the fuzzer.
contract CoverPoolHandler is CommonBase, StdUtils {
    CoverPool public immutable pool;
    TestUSDT public immutable asset;

    /// @dev A small fixed actor set. Capital-provider accounting is share-based, so bugs surface
    ///      through several providers interleaving deposits and withdrawals, not through many.
    address[4] public actors;

    /// @dev Policy ids are drawn from a small range so that reserve, release and payout calls
    ///      collide on the same policy — where the double-release and double-pay bugs live.
    uint256 internal constant POLICY_COUNT = 16;

    /// @notice Every policy id the handler has ever reserved cover against.
    uint256[] public touchedPolicies;
    mapping(uint256 => bool) internal seen;

    /// @notice Call counts, reported by the invariant test so a silently unproductive run is
    ///         visible rather than passing as proof.
    mapping(bytes32 => uint256) public calls;

    constructor(CoverPool pool_, TestUSDT asset_) {
        pool = pool_;
        asset = asset_;

        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA401);
        actors[3] = address(0xDA1E);

        for (uint256 i = 0; i < actors.length; i++) {
            asset.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            asset.approve(address(pool), type(uint256).max);
        }
    }

    modifier count(bytes32 name) {
        calls[name]++;
        _;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _policy(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1, POLICY_COUNT);
    }

    function _track(uint256 policyId) internal {
        if (!seen[policyId]) {
            seen[policyId] = true;
            touchedPolicies.push(policyId);
        }
    }

    function touchedPoliciesLength() external view returns (uint256) {
        return touchedPolicies.length;
    }

    // --- capital providers ----------------------------------------------------------------

    function depositCapital(uint256 actorSeed, uint256 assets) external count("depositCapital") {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, asset.balanceOf(actor));
        vm.prank(actor);
        pool.depositCapital(assets);
    }

    function withdrawCapital(uint256 actorSeed, uint256 shares) external count("withdrawCapital") {
        address actor = _actor(actorSeed);
        uint256 held = pool.sharesOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(actor);
        pool.withdrawCapital(shares);
    }

    // --- underwriting ---------------------------------------------------------------------

    function reserveCover(uint256 policySeed, uint256 amount) external count("reserveCover") {
        uint256 policyId = _policy(policySeed);
        // Deliberately allowed to exceed free capital: the over-reservation revert is the
        // invariant's primary defence and must stay on the fuzzer's path.
        amount = bound(amount, 1, pool.capital() + 1_000e6);
        _track(policyId);
        vm.prank(address(this));
        pool.reserveCover(policyId, amount);
    }

    function releaseCover(uint256 policySeed) external count("releaseCover") {
        uint256 policyId = _policy(policySeed);
        pool.releaseCover(policyId);
    }

    function payClaim(uint256 policySeed, uint256 amount, uint256 actorSeed)
        external
        count("payClaim")
    {
        uint256 policyId = _policy(policySeed);
        uint256 reserved = pool.coverOf(policyId);
        if (reserved == 0) return;
        // Bounded well above the reservation rather than one wei past it, so the over-payout revert
        // is exercised at a realistic magnitude instead of at the smallest value that reaches it.
        //
        // Note what this does *not* buy: deleting the cap in `payClaim` leaves every invariant here
        // green at either bound. Over-paying a claim does not make the pool insolvent — `payClaim`
        // drops `outstandingCover` alongside `capital`, and `reserveCover` is gated on free capital,
        // so the book stays covered. It is theft from the providers, not insolvency, and no solvency
        // property can see it. That guard is asserted directly in `test/unit/CoverPool.t.sol`, which
        // is where a specific-input rejection belongs.
        amount = bound(amount, 1, reserved * 2 + 1);
        pool.payClaim(policyId, _actor(actorSeed), amount);
    }

    function accruePremium(uint256 actorSeed, uint256 amount) external count("accruePremium") {
        address actor = _actor(actorSeed);
        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        pool.accruePremium(amount);
    }

    // --- adversarial ----------------------------------------------------------------------

    /// @notice Send assets straight to the pool, bypassing `accruePremium` entirely.
    /// @dev Nobody would do this on purpose; someone will do it by accident. Internal accounting
    ///      must not credit it, and the balance-backs-capital invariant must survive it.
    function donate(uint256 actorSeed, uint256 amount) external count("donate") {
        address actor = _actor(actorSeed);
        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        asset.transfer(address(pool), amount);
    }

    /// @notice Pause and unpause issuance mid-sequence.
    /// @dev Pausing must never strand a withdrawal or a claim (SPEC §4.7), so the fuzzer gets to
    ///      interleave a pause with both.
    function togglePause(uint256 seed) external count("togglePause") {
        if (bound(seed, 0, 1) == 0) {
            if (!pool.paused()) pool.pauseIssuance();
        } else {
            if (pool.paused()) pool.unpauseIssuance();
        }
    }
}
