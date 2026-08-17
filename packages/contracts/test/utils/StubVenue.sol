// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";

/// @notice A venue whose three sampled readings can be set directly, for unit tests only.
/// @dev SPEC §1.2.1 forbids a stub standing in for a real dependency anywhere outside a unit test,
///      and this lives under `test/` for that reason: nothing in `src/` imports it, no deployment
///      script references it, and no number it returns is ever shown to a user.
///
///      It exists because the trigger conditions cannot be produced on demand against a real
///      venue — a reserve deficit on X Layer mainnet is not something a test may cause, and waiting
///      for one is not a test strategy. The resolver's behaviour under those conditions still has to
///      be proven, so the conditions are set here, while the *read path* through a real venue is
///      proven separately: `test/fork/` reads live Aave through `AaveV3Venue`, and the testnet
///      deployment reads `TestnetVenue`'s own real state.
contract StubVenue is IYieldVenue {
    uint256 public deficit;
    uint256 public price;

    IERC20 public asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setDeficit(uint256 v) external {
        deficit = v;
    }

    function setPrice(uint256 v) external {
        price = v;
    }

    /// @dev Only the deficit and the price are stubbed. Redeemable liquidity is read from the real
    ///      token balance at `aToken`, exactly as `AaveV3Venue` and `TestnetVenue` both read it, so
    ///      a test that drains liquidity has to actually move tokens to do it.
    function observeReserve(address reserve, address aToken)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return (deficit, price, IERC20(reserve).balanceOf(aToken));
    }

    function venueName() external pure returns (string memory) {
        return "stub/unit-test";
    }

    function hasYieldSource() external pure returns (bool) {
        return false;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function deposit(uint256) external pure returns (uint256) {
        revert("not used in these tests");
    }

    function withdraw(uint256, address) external pure returns (uint256) {
        revert("not used in these tests");
    }
}
