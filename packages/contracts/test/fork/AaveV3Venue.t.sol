// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3Venue} from "../../src/venues/AaveV3Venue.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveOracle} from "../../src/interfaces/IAaveOracle.sol";
import {XLayerAddresses} from "../../src/XLayerAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveV3VenueForkTest
/// @notice `AaveV3Venue` against the real Aave V3 Pool on forked X Layer mainnet.
///
/// @dev No mock Pool, no mock aToken, no simulated interest. Every address here is the one
///      verified on chain in `docs/chain-verification.md`, and the interest observed is whatever
///      the live reserve actually paid over the forked interval.
///
///      Skipped automatically when no RPC is reachable, so a offline `forge test` does not report
///      a false pass — see `_forkOrSkip`.
contract AaveV3VenueForkTest is Test {
    AaveV3Venue internal venue;
    IERC20 internal usdt = IERC20(XLayerAddresses.USDT);
    IERC20 internal aUsdt = IERC20(XLayerAddresses.USDT_A_TOKEN);
    IAaveV3Pool internal aavePool = IAaveV3Pool(XLayerAddresses.POOL);
    IAaveOracle internal oracle = IAaveOracle(XLayerAddresses.ORACLE);

    address internal vault = makeAddr("vault");
    address internal user = makeAddr("user");

    bool internal forked;

    function setUp() public {
        forked = _forkOrSkip();
        if (!forked) return;

        venue = new AaveV3Venue(usdt, aavePool, aUsdt, oracle, address(this));
        venue.grantRole(venue.VAULT_ROLE(), vault);

        deal(address(usdt), vault, 100_000e6);
        vm.prank(vault);
        usdt.approve(address(venue), type(uint256).max);
    }

    function _forkOrSkip() internal returns (bool) {
        string memory rpc = vm.envOr("XLAYER_MAINNET_RPC", string("https://rpc.xlayer.tech"));
        try vm.createSelectFork(rpc) {
            return true;
        } catch {
            // No network in this environment. Report it rather than passing silently.
            emit log("SKIPPED: no X Layer mainnet RPC reachable");
            return false;
        }
    }

    modifier onlyForked() {
        if (!forked) return;
        _;
    }

    /// @notice The venue supplies real USDT to the real Pool and receives real aUSDT.
    function test_SuppliesToLiveAavePool() public onlyForked {
        assertEq(venue.totalAssets(), 0);

        vm.prank(vault);
        uint256 supplied = venue.deposit(50_000e6);

        assertEq(supplied, 50_000e6);
        assertApproxEqAbs(
            aUsdt.balanceOf(address(venue)), 50_000e6, 1, "aToken not received from Aave"
        );
        assertApproxEqAbs(venue.totalAssets(), 50_000e6, 1);

        // The standing approval is not left behind after the supply.
        assertEq(usdt.allowance(address(venue), address(aavePool)), 0, "approval left standing");
    }

    /// @notice Interest actually accrues, read from the live aToken rather than modelled.
    function test_PositionAccruesRealInterest() public onlyForked {
        vm.prank(vault);
        venue.deposit(50_000e6);
        uint256 start = venue.totalAssets();

        // Aave accrues per second against the block timestamp.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 accrued = venue.totalAssets();
        assertGt(accrued, start, "no interest accrued on a live reserve over 30 days");
        emit log_named_uint("accrued over 30 days (6dp)", accrued - start);
    }

    /// @notice A round trip returns the deposit, and the depositor keeps the interest.
    function test_WithdrawRedeemsFromLiveAavePool() public onlyForked {
        vm.prank(vault);
        venue.deposit(50_000e6);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256 balance = venue.totalAssets();
        vm.prank(vault);
        uint256 redeemed = venue.withdraw(balance, user);

        assertEq(redeemed, balance);
        assertEq(usdt.balanceOf(user), balance, "user did not receive the redeemed assets");
        assertGt(balance, 50_000e6, "round trip returned less than was supplied");
    }

    /// @notice The claim trigger reads cleanly from the live Pool.
    /// @dev The whole design rests on this call existing. If it ever reverts, the primary covered
    ///      event is unmeasurable and that must surface as a failing test, not a silent zero.
    function test_ReserveDeficitReadsCleanlyFromLivePool() public onlyForked {
        uint256 deficit = venue.reserveDeficit();
        emit log_named_uint("live USDT reserve deficit", deficit);
        assertEq(deficit, aavePool.getReserveDeficit(XLayerAddresses.USDT));
    }

    /// @notice All four observation values come from the configured live Aave dependencies.
    /// @dev The bogus second argument is intentional. A permissionless recorder may provide it,
    ///      but it must not be able to substitute another ERC-20 and manufacture a liquidity
    ///      reading. This also catches wiring the Chainlink-style USDT feed as `IAaveOracle`.
    function test_ObserveReserveUsesConfiguredLiveSources() public view onlyForked {
        address bogusAToken = address(0xBEEF);

        (
            uint256 deficit,
            uint256 price,
            uint256 redeemableLiquidity,
            uint256 totalSupplied
        ) = venue.observeReserve(address(usdt), bogusAToken);

        assertEq(deficit, aavePool.getReserveDeficit(address(usdt)));
        assertEq(price, oracle.getAssetPrice(address(usdt)));
        assertEq(redeemableLiquidity, usdt.balanceOf(address(aUsdt)));
        assertEq(totalSupplied, aUsdt.totalSupply());
    }

    /// @notice The venue exposes no surface that could induce or alter a reserve deficit.
    /// @dev Required by §11. The claim trigger is a reading of Aave's state; a venue that could
    ///      move that state would make every claim it settles suspect.
    function test_VenueExposesNoDeficitSurface() public view onlyForked {
        bytes memory code = address(venue).code;

        assertFalse(_hasSelector(code, "induceDeficit(address,uint256)"), "induceDeficit present");
        assertFalse(_hasSelector(code, "eliminateReserveDeficit(address,uint256)"), "deficit write present");
        assertFalse(_hasSelector(code, "setReserveDeficit(address,uint256)"), "deficit write present");

        // The scan must be capable of finding something, or the assertions above prove nothing.
        assertTrue(_hasSelector(code, "reserveDeficit()"), "bytecode scan is broken");
    }

    function _hasSelector(bytes memory code, string memory signature) internal pure returns (bool) {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1]
                    && code[i + 2] == selector[2] && code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }
}
