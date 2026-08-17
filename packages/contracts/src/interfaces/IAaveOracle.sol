// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of the Aave oracle xCover reads.
/// @dev Verified live on X Layer mainnet at `0x91FC11136d5615575a0fC5981Ab5C0C54418E2C6`,
///      returning `99896524` for USDT — $0.99896524 at 8 decimals. Note that normal conditions
///      are already ~10 bp off peg, so any depeg threshold must clear that or it fires on noise.
interface IAaveOracle {
    /// @notice Price of `asset` in the oracle's base currency, 8 decimals.
    function getAssetPrice(address asset) external view returns (uint256);
}
