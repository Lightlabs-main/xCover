// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {XLayerAddresses as A} from "../src/XLayerAddresses.sol";

interface IPoolLike {
    function getReserveDeficit(address asset) external view returns (uint256);
    function POOL_REVISION() external view returns (uint256);
}

interface IDataProviderLike {
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}

interface IOracleLike {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IERC20Like {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice Asserts that every Aave address xCover depends on still responds as
///         recorded in docs/chain-verification.md. Run before every deployment
///         and in CI.
///
///         An address book entry can go stale, a reserve can be frozen, an
///         oracle can start returning zero. Each of those silently changes what
///         the product means. A failing assertion here catches it before a user
///         buys cover against an assumption that stopped being true.
///
///         Read-only. Broadcasts nothing.
contract VerifyIntegration is Script {
    /// @dev The claim is denominated in the covered asset, so an oracle far off
    ///      peg is a signal, not a failure. Bound the sanity check loosely: this
    ///      catches a dead or broken feed, not a depeg. Depeg detection is
    ///      ClaimResolver's job, against a threshold derived from data.
    uint256 internal constant MIN_SANE_PRICE = 0.90e8;
    uint256 internal constant MAX_SANE_PRICE = 1.10e8;

    function run() external view {
        require(block.chainid == A.CHAIN_ID_MAINNET, "VerifyIntegration: Aave is mainnet-only, run against chain 196");

        console.log("xCover integration verification");
        console.log("  chain id     ", block.chainid);
        console.log("  block        ", block.number);
        console.log("  timestamp    ", block.timestamp);

        _checkCodePresent(A.POOL, "POOL");
        _checkCodePresent(A.POOL_ADDRESSES_PROVIDER, "POOL_ADDRESSES_PROVIDER");
        _checkCodePresent(A.ORACLE, "ORACLE");
        _checkCodePresent(A.DATA_PROVIDER, "DATA_PROVIDER");
        _checkCodePresent(A.USDT, "USDT");
        _checkCodePresent(A.USDT_A_TOKEN, "USDT_A_TOKEN");

        _checkPoolRevision();
        _checkDeficitTriggerAvailable();
        _checkReserveLive();
        _checkRealDeposits();
        _checkOracleLive();

        console.log("");
        console.log("All integration assumptions hold.");
    }

    function _checkCodePresent(address target, string memory name) internal view {
        require(target.code.length > 0, string.concat("VerifyIntegration: no code at ", name));
    }

    /// @dev The single blocking dependency for the primary claim trigger. A
    ///      revert here means the deficit trigger is not available and the
    ///      product must fall back to redemption failure as primary — a change
    ///      that has to be made deliberately and stated in the README, never
    ///      absorbed silently.
    function _checkDeficitTriggerAvailable() internal view {
        uint256 deficit = IPoolLike(A.POOL).getReserveDeficit(A.USDT);
        console.log("  reserve deficit (USDT)", deficit);
    }

    function _checkPoolRevision() internal view {
        uint256 revision = IPoolLike(A.POOL).POOL_REVISION();
        console.log("  pool revision", revision);
        require(
            revision >= A.EXPECTED_POOL_REVISION,
            "VerifyIntegration: pool revision below the one getReserveDeficit was verified against"
        );
    }

    function _checkReserveLive() internal view {
        (
            uint256 decimals,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool isActive,
            bool isFrozen
        ) = IDataProviderLike(A.DATA_PROVIDER).getReserveConfigurationData(A.USDT);

        require(decimals == A.USDT_DECIMALS, "VerifyIntegration: USDT decimals changed");
        require(isActive, "VerifyIntegration: USDT reserve is not active");
        require(!isFrozen, "VerifyIntegration: USDT reserve is frozen");
        console.log("  reserve active, unfrozen, decimals", decimals);
    }

    /// @dev Cover written against an empty reserve would be meaningless. This
    ///      also pins the denominator for any claim about what share of the
    ///      reserve xCover covers.
    function _checkRealDeposits() internal view {
        uint256 supply = IERC20Like(A.USDT_A_TOKEN).totalSupply();
        require(supply > 0, "VerifyIntegration: aToken supply is zero, reserve has no deposits");
        console.log("  aUSDT total supply", supply);
    }

    function _checkOracleLive() internal view {
        uint256 price = IOracleLike(A.ORACLE).getAssetPrice(A.USDT);
        require(price != 0, "VerifyIntegration: oracle returned zero, feed is dead");
        require(
            price >= MIN_SANE_PRICE && price <= MAX_SANE_PRICE,
            "VerifyIntegration: oracle price outside sane band, inspect before deploying"
        );
        console.log("  USDT price (8dp)", price);
    }
}
