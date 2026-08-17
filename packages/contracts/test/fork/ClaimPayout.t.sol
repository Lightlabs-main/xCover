// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {ClaimResolver} from "../../src/ClaimResolver.sol";
import {AaveV3Venue} from "../../src/venues/AaveV3Venue.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveOracle} from "../../src/interfaces/IAaveOracle.sol";
import {XLayerAddresses} from "../../src/XLayerAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ClaimPayoutForkTest
/// @notice The payout, end to end, against the real Aave V3 deployment on X Layer mainnet.
///         SPEC §6.1 calls this the primary artifact, and this is it.
///
/// @dev **What is real here.** The Pool, the oracle, the USDT, the aUSDT and the depositors whose
///      50M sits in that reserve are all the live mainnet ones at the addresses verified in
///      `docs/chain-verification.md`. The covered position is really supplied to Aave and really
///      earns interest. The observations are read out of Aave's own storage through its own
///      getter. The payout moves real USDT to the policy holder.
///
///      **What is synthetic, stated plainly.** X Layer's USDT reserve is healthy: no deficit, at
///      peg, deeply liquid. A test may not cause a real bad-debt event, and waiting for one is
///      not a test strategy. So the deficit is written directly into the live Pool's storage on
///      the fork, and everything downstream reacts to it exactly as it would to a real one — the
///      value is planted, the code reading it is Aave's own deployed bytecode, unmodified.
///
///      That distinction is the whole reason this test is worth more than the unit tests: those
///      prove the resolver's logic against a stand-in, this proves it against the real contract
///      at the real address. Neither claims a real deficit occurred, and the README says so.
contract ClaimPayoutForkTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    ClaimResolver internal resolver;
    AaveV3Venue internal venue;

    IERC20 internal usdt = IERC20(XLayerAddresses.USDT);
    IERC20 internal aUsdt = IERC20(XLayerAddresses.USDT_A_TOKEN);
    IAaveV3Pool internal aavePool = IAaveV3Pool(XLayerAddresses.POOL);
    IAaveOracle internal oracle = IAaveOracle(XLayerAddresses.ORACLE);

    address internal vault = makeAddr("vault");
    address internal provider = makeAddr("provider");
    address internal depositor = makeAddr("depositor");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant WAITING = 100;
    uint64 internal constant WINDOW = 50;
    uint64 internal constant MIN_SAMPLES = 5;
    /// @dev 0.5% of the reserve unbacked. See ClaimResolver._deficitBps for the measurements this
    ///      floor was chosen from.
    uint256 internal constant DEFICIT_FLOOR_BPS = 50;
    uint256 internal constant CAPITAL = 500_000e6;
    uint256 internal constant DEPOSIT = 50_000e6;

    /// @dev EIP-1967: keccak256("eip1967.proxy.implementation") - 1.
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    ClaimResolver.Terms internal terms;
    bytes32 internal termsHash;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("XLAYER_MAINNET_RPC", string("https://rpc.xlayer.tech"));
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            emit log("SKIPPED: no X Layer mainnet RPC reachable");
            return;
        }

        pool = new CoverPool(usdt, address(this));
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, 1_000_000e6, address(this));
        // The venue is constructed first because the resolver reads its triggers through it. On
        // this fork those reads land on the live Aave Pool and the live oracle, so nothing about
        // the evidence this test produces is weakened by the indirection.
        venue = new AaveV3Venue(usdt, aavePool, aUsdt, oracle, address(this));
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
        venue.grantRole(venue.VAULT_ROLE(), vault);

        terms = ClaimResolver.Terms({
            reserve: XLayerAddresses.USDT,
            aToken: XLayerAddresses.USDT_A_TOKEN,
            windowBlocks: WINDOW,
            minSamples: MIN_SAMPLES,
            depegLowerBound: 97_000_000, // clear of the ~10 bp of normal drift
            liquidityFloorBps: 10_000,
            deficitFloorBps: DEFICIT_FLOOR_BPS
        });
        termsHash = _hashTerms(terms);

        // Real underwriting capital, and a real position for the depositor to have covered.
        deal(address(usdt), provider, CAPITAL);
        vm.startPrank(provider);
        usdt.approve(address(pool), type(uint256).max);
        pool.depositCapital(CAPITAL);
        vm.stopPrank();

        deal(address(usdt), vault, DEPOSIT);
        vm.prank(vault);
        usdt.approve(address(venue), type(uint256).max);
    }

    modifier onlyForked() {
        if (!forked) return;
        _;
    }

    // --- storage discovery ----------------------------------------------------------------

    /// @notice Plant a reserve deficit in the live Pool's storage, verified through its getter.
    /// @dev The slot is discovered rather than hardcoded: record every slot `getReserveDeficit`
    ///      reads, then write to each in turn until Aave's own getter reports the value back.
    ///      A hardcoded slot would silently target the wrong field after any Aave upgrade; this
    ///      fails loudly instead, which is the behaviour an integration assumption deserves.
    ///
    ///      `deficit` is a packed field, so each candidate is tried at both 128-bit offsets and
    ///      the surrounding bits of the word are preserved.
    function _plantDeficit(address asset, uint256 amount) internal {
        vm.record();
        aavePool.getReserveDeficit(asset);
        (bytes32[] memory reads,) = vm.accesses(address(aavePool));

        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 slot = reads[i];

            // The Pool is a proxy, and the first slot it reads on any call is the ERC-1967
            // implementation pointer. Writing there repoints the proxy at a garbage address and
            // bricks it for the rest of the test — every later call returns empty and the failure
            // surfaces somewhere unrelated. Skip it.
            if (slot == ERC1967_IMPLEMENTATION_SLOT) continue;

            bytes32 original = vm.load(address(aavePool), slot);

            for (uint256 shift = 0; shift <= 128; shift += 128) {
                uint256 mask = uint256(type(uint128).max) << shift;
                bytes32 candidate =
                    bytes32((uint256(original) & ~mask) | ((amount << shift) & mask));

                vm.store(address(aavePool), slot, candidate);

                // Probed with a low-level call: a wrong guess can leave the Pool unable to answer
                // at all, and that must not abort the search before the slot is restored.
                (bool ok, bytes memory ret) = address(aavePool).staticcall(
                    abi.encodeWithSelector(IAaveV3Pool.getReserveDeficit.selector, asset)
                );
                if (ok && ret.length == 32 && abi.decode(ret, (uint256)) == amount) {
                    return;
                }

                vm.store(address(aavePool), slot, original);
            }
        }

        revert(
            "could not locate the reserve deficit slot: Aave's storage layout has changed, so this test's assumption is stale"
        );
    }

    // --- helpers --------------------------------------------------------------------------

    function _hashTerms(ClaimResolver.Terms memory t) internal view returns (bytes32) {
        ClaimResolver.Terms[] memory arr = new ClaimResolver.Terms[](1);
        arr[0] = t;
        return this.hashTerms(arr);
    }

    function hashTerms(ClaimResolver.Terms[] calldata t) external view returns (bytes32) {
        return resolver.hashTerms(t[0]);
    }

    function evaluate(uint256 id, ClaimResolver.Terms[] calldata t)
        external
        returns (ClaimResolver.Trigger)
    {
        return resolver.evaluate(id, t[0]);
    }

    function _evaluate(uint256 id) internal returns (ClaimResolver.Trigger) {
        ClaimResolver.Terms[] memory arr = new ClaimResolver.Terms[](1);
        arr[0] = terms;
        return this.evaluate(id, arr);
    }

    function _observe(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(stranger); // permissionless
            resolver.recordObservation(XLayerAddresses.USDT, XLayerAddresses.USDT_A_TOKEN);
            vm.roll(block.number + 1);
        }
    }

    // --- the payout ------------------------------------------------------------------------

    /// @notice Deposit → cover → real deficit in the live Pool → claim → USDT in the wallet.
    function test_FullPayoutPathAgainstLiveAave() public onlyForked {
        // 1. The depositor's position is really supplied to Aave.
        vm.prank(vault);
        venue.deposit(DEPOSIT);
        assertApproxEqAbs(aUsdt.balanceOf(address(venue)), DEPOSIT, 1, "position not in Aave");

        // 2. Cover is minted against it, backed by real capital locked in the pool.
        vm.prank(vault);
        uint256 id = policy.mintPolicy(
            depositor,
            XLayerAddresses.USDT,
            DEPOSIT,
            uint64(block.number) + 100_000,
            1e21,
            keccak256("quote"),
            termsHash
        );
        assertEq(pool.coverOf(id), DEPOSIT);
        assertEq(pool.freeCapital(), CAPITAL - DEPOSIT);

        // 3. The waiting period elapses. Cover goes live.
        vm.roll(policy.activeFromBlock(id));
        assertTrue(policy.isCoverActive(id));

        // Healthy conditions do not pay. Confirmed against the live reserve before anything is
        // planted, so the trigger below is a change of state rather than a foregone conclusion.
        assertEq(aavePool.getReserveDeficit(XLayerAddresses.USDT), 0, "reserve is not healthy");
        _observe(MIN_SAMPLES);
        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);

        // Let the healthy readings age out of the window. They are not discarded — nothing here
        // rewrites history — they simply fall outside it as blocks pass, which is why a policy
        // cannot be triggered by a condition that has already ended.
        vm.roll(block.number + WINDOW + 1);

        // 4. A deficit appears in the live Pool's own storage, read back through its own getter.
        _plantDeficit(XLayerAddresses.USDT, 250_000e6);
        assertEq(
            aavePool.getReserveDeficit(XLayerAddresses.USDT),
            250_000e6,
            "the live Pool does not report the deficit"
        );

        // 5. It has to persist across the window; observations are recorded as blocks pass.
        _observe(MIN_SAMPLES);

        // 6. Evaluation, against the real Pool.
        ClaimResolver.Trigger trigger = _evaluate(id);
        assertEq(uint8(trigger), uint8(ClaimResolver.Trigger.ReserveDeficit));
        assertEq(resolver.claimAmount(id), DEPOSIT);
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Claimable));

        // 7. Anyone may settle it, and the money goes to the holder.
        uint256 before = usdt.balanceOf(depositor);
        vm.prank(stranger);
        uint256 paid = resolver.claim(id);

        assertEq(paid, DEPOSIT);
        assertEq(usdt.balanceOf(depositor) - before, DEPOSIT, "the holder was not paid real USDT");
        assertEq(usdt.balanceOf(stranger), 0, "the settler was paid instead of the holder");
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Paid));

        // 8. The pool remains solvent after paying.
        assertGe(pool.capital(), pool.outstandingCover(), "insolvent after a real payout");
        assertEq(pool.capital(), CAPITAL - DEPOSIT);
        assertEq(pool.outstandingCover(), 0);

        emit log_named_uint("paid to holder (USDT, 6dp)", paid);
    }

    /// @notice The depositor's underlying position is untouched by the claim.
    /// @dev xCover pays the depositor for their loss. It does not seize, unwind, or repair the
    ///      position, and it does not reduce Aave's deficit — §2.4, asserted rather than asserted
    ///      about.
    function test_PayoutDoesNotTouchTheUnderlyingPosition() public onlyForked {
        vm.prank(vault);
        venue.deposit(DEPOSIT);
        uint256 positionBefore = venue.totalAssets();

        vm.prank(vault);
        uint256 id = policy.mintPolicy(
            depositor,
            XLayerAddresses.USDT,
            DEPOSIT,
            uint64(block.number) + 100_000,
            1e21,
            keccak256("quote"),
            termsHash
        );
        vm.roll(policy.activeFromBlock(id));

        _plantDeficit(XLayerAddresses.USDT, 250_000e6);
        _observe(MIN_SAMPLES);
        _evaluate(id);
        resolver.claim(id);

        assertGe(venue.totalAssets(), positionBefore, "the claim disturbed the covered position");
        assertEq(
            aavePool.getReserveDeficit(XLayerAddresses.USDT),
            250_000e6,
            "xCover altered Aave's deficit, which it must never do"
        );
    }

    /// @notice A deficit that does not persist across the window does not pay.
    /// @dev The flash-loan defence, exercised against the real Pool rather than a stand-in.
    function test_ATransientDeficitDoesNotPayOnLiveAave() public onlyForked {
        vm.prank(vault);
        uint256 id = policy.mintPolicy(
            depositor,
            XLayerAddresses.USDT,
            DEPOSIT,
            uint64(block.number) + 100_000,
            1e21,
            keccak256("quote"),
            termsHash
        );
        vm.roll(policy.activeFromBlock(id));

        _plantDeficit(XLayerAddresses.USDT, 250_000e6);
        _observe(MIN_SAMPLES - 1);

        // The deficit clears for a single block inside the window.
        _plantDeficit(XLayerAddresses.USDT, 0);
        _observe(1);

        _plantDeficit(XLayerAddresses.USDT, 250_000e6);
        _observe(MIN_SAMPLES);

        vm.expectRevert(abi.encodeWithSelector(ClaimResolver.NoTriggerMet.selector, id));
        _evaluate(id);
    }
}
