// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";

/// @notice Drives the pool through `CoverPolicy` rather than calling it directly.
/// @dev `CoverPoolHandler` proves the pool's own arithmetic holds. This one proves the property
///      survives the path the product actually uses: obligations created only by minting a policy,
///      and released only by a lifecycle transition. A solvency bug that lives in the seam between
///      the two contracts — a release that fires twice, a claim paid against a cancelled policy —
///      is invisible to the first handler and reachable by this one.
contract CoverSystemHandler is CommonBase, StdUtils {
    CoverPool public immutable pool;
    CoverPolicy public immutable policy;
    TestUSDT public immutable asset;

    address[3] public actors;

    /// @notice Every policy id minted, so the invariants can walk the whole book.
    uint256[] public policyIds;

    mapping(bytes32 => uint256) public calls;

    constructor(CoverPool pool_, CoverPolicy policy_, TestUSDT asset_) {
        pool = pool_;
        policy = policy_;
        asset = asset_;

        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA401);

        for (uint256 i = 0; i < actors.length; i++) {
            asset.mint(actors[i], 5_000_000e6);
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

    function policyCount() external view returns (uint256) {
        return policyIds.length;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        if (policyIds.length == 0) return (0, false);
        return (policyIds[bound(seed, 0, policyIds.length - 1)], true);
    }

    // --- capital --------------------------------------------------------------------------

    function depositCapital(uint256 actorSeed, uint256 assets) external count("depositCapital") {
        address actor = _actor(actorSeed);
        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) return;
        assets = bound(assets, 1, balance);
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

    function accruePremium(uint256 actorSeed, uint256 amount) external count("accruePremium") {
        address actor = _actor(actorSeed);
        uint256 balance = asset.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        pool.accruePremium(amount);
    }

    // --- issuance and lifecycle -----------------------------------------------------------

    function mintPolicy(uint256 actorSeed, uint256 coverAmount, uint256 termSeed)
        external
        count("mintPolicy")
    {
        // Sized so that most draws are writable and the rejection paths — daily cap, and free
        // capital once enough cover is outstanding — are both still reachable. Bounding this by
        // total capital instead makes the cap reject nearly every draw, and the book stays empty.
        coverAmount = bound(coverAmount, 1, 400_000e6);
        uint64 term = uint64(bound(termSeed, policy.waitingPeriodBlocks() + 1, 50_000));

        uint256 id = policy.mintPolicy(
            _actor(actorSeed),
            address(asset),
            coverAmount,
            uint64(block.number) + term,
            1e21,
            keccak256(abi.encode(coverAmount)),
            keccak256("terms")
        );
        policyIds.push(id);
    }

    function expirePolicy(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        calls["expirePolicy"]++;
        policy.expire(id);
    }

    function cancelPolicy(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        calls["cancelPolicy"]++;
        policy.cancel(id);
    }

    function markClaimable(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        calls["markClaimable"]++;
        policy.markClaimable(id);
    }

    /// @notice Settle a claimable policy the way ClaimResolver will: pay, then mark paid.
    function settleClaim(uint256 seed, uint256 amountSeed, uint256 actorSeed)
        external
    {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        uint256 reserved = pool.coverOf(id);
        if (reserved == 0) return;
        calls["settleClaim"]++;
        uint256 amount = bound(amountSeed, 1, reserved);

        pool.payClaim(id, _actor(actorSeed), amount);
        policy.markPaid(id, amount);
    }

    // --- environment ----------------------------------------------------------------------

    /// @notice Advance blocks so waiting periods elapse and policy terms end.
    /// @dev X Layer blocks are seconds apart, so a plausible number of blocks moves the clock by
    ///      far less than a day. That is why crossing a day boundary needs its own action below.
    function advance(uint256 blocksSeed) external count("advance") {
        uint256 n = bound(blocksSeed, 1, 20_000);
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n * 2);
    }

    /// @notice Cross a day boundary so the per-reserve daily cap resets.
    /// @dev Without this the cap is spent once and never refreshed, every later mint reverts, and
    ///      the invariants pass over an empty book — a green run proving nothing.
    function advanceDay(uint256 daysSeed) external count("advanceDay") {
        uint256 d = bound(daysSeed, 1, 3);
        vm.warp(block.timestamp + d * 1 days);
        vm.roll(block.number + d * 43_200);
    }

    function togglePause(uint256 seed) external count("togglePause") {
        if (bound(seed, 0, 1) == 0) {
            if (!pool.paused()) pool.pauseIssuance();
        } else {
            if (pool.paused()) pool.unpauseIssuance();
        }
    }
}
