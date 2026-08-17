// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of the Aave V3 Pool that xCover depends on.
/// @dev Deliberately minimal. Every function here was confirmed to exist and return cleanly
///      against the live X Layer mainnet Pool at `0xE3F3Caefdd7180F884c01E57f65Df979Af84f116`
///      (revision 11) — see `docs/chain-verification.md`. `getReserveDeficit` is the primary
///      claim trigger and its presence was the single blocking dependency for the whole design.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Bad debt recorded against a reserve. The primary covered event.
    function getReserveDeficit(address asset) external view returns (uint256);
}
