// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveOracle} from "../../src/interfaces/IAaveOracle.sol";

/// @notice Controllable Aave Pool and oracle, for unit tests only.
/// @dev SPEC §1.2.1 forbids a `MockAavePool` or `MockOracle` anywhere outside a unit test, and
///      these live under `test/` for exactly that reason: nothing in `src/` imports them, no
///      deployment script references them, and no number they return is ever shown to a user.
///
///      They exist because the trigger conditions cannot be produced on demand against the real
///      chain — a reserve deficit on X Layer mainnet is not something a test may cause, and
///      waiting for one is not a test strategy. The behaviour under those conditions still has to
///      be proven, so the conditions are set here and the *read path* against the real Pool is
///      proven separately in `test/fork/`, where the addresses are the verified live ones.
contract StubAavePool is IAaveV3Pool {
    mapping(address => uint256) public deficit;

    function setDeficit(address asset, uint256 amount) external {
        deficit[asset] = amount;
    }

    function getReserveDeficit(address asset) external view returns (uint256) {
        return deficit[asset];
    }

    function supply(address, uint256, address, uint16) external pure {
        revert("not used in these tests");
    }

    function withdraw(address, uint256, address) external pure returns (uint256) {
        revert("not used in these tests");
    }
}

contract StubAaveOracle is IAaveOracle {
    mapping(address => uint256) public price;

    constructor() {
        // Default to the price actually observed on X Layer mainnet on 2026-08-17, so a test
        // that does not deliberately move the price runs against a realistic starting point —
        // including its ~10 bp of normal off-peg drift.
        // (Set per-asset by the test; this is the value used.)
    }

    function setPrice(address asset, uint256 price_) external {
        price[asset] = price_;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return price[asset];
    }
}
