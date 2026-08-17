// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IYieldVenue
/// @notice The yield source a covered position is supplied to.
///
/// @dev This abstraction is **required, not a convenience**. Aave V3 is not deployed on X Layer
///      testnet — verified on 2026-08-17, empty code at both `POOL` and
///      `POOL_ADDRESSES_PROVIDER` — so the testnet deployment cannot supply to Aave and the
///      mainnet deployment must. One interface, two implementations, chosen by chain:
///
///          mainnet (196)   AaveV3Venue    supplies to the real Aave V3 Pool
///          testnet (1952)  TestnetVenue   custodies only; there is no yield source
///
///      `venueName()` exists so a deployment cannot quietly misrepresent which of those it is.
///      The frontend and `docs/deployments.md` both read it and state the answer plainly, because
///      a testnet demo implying a live Aave integration behind it would be a lie by omission.
interface IYieldVenue {
    /// @notice Assets were supplied to the venue.
    event Supplied(uint256 assets);
    /// @notice Assets were redeemed from the venue.
    event Redeemed(uint256 assets, address indexed to);

    /// @notice The venue returned less than was asked for.
    error InsufficientVenueLiquidity(uint256 requested, uint256 returned);
    /// @notice Zero-valued calls are rejected rather than silently succeeding.
    error ZeroAmount();

    /// @notice The asset this venue accepts. USDT at launch.
    function asset() external view returns (IERC20);

    /// @notice Human-readable identity of the backing venue, e.g. "aave-v3/xlayer-mainnet".
    /// @dev Surfaced in the UI and in the deployment record so nobody has to infer it.
    function venueName() external view returns (string memory);

    /// @notice True when a real external yield source backs this venue.
    /// @dev False for `TestnetVenue`. Read this rather than assuming.
    function hasYieldSource() external view returns (bool);

    /// @notice Assets currently held on behalf of the caller's deposits, including any accrued.
    function totalAssets() external view returns (uint256);

    /// @notice The three readings `ClaimResolver` samples, taken live at the current block.
    ///
    /// @dev The claim triggers are defined against the venue the position actually sits in, so the
    ///      venue is what reports them. Binding the resolver to `IAaveV3Pool` directly would make
    ///      the trigger unreadable on a chain where Aave does not exist, which is the chain the
    ///      testnet deployment runs on — the judge-triggerable claim in SPEC §3.5 depends on this
    ///      being interface-bound.
    ///
    ///      **Every value is read here and now.** No implementation may accept a reading from its
    ///      caller. A caller therefore chooses only *when* a true reading is taken, never what it
    ///      says, which is the property the resolver's manipulation resistance rests on.
    ///
    /// @param reserve The covered asset.
    /// @param aToken The interest-bearing claim on it, whose underlying balance is the redeemable
    ///        liquidity. Ignored by venues that hold the underlying directly.
    /// @return deficit Unbacked obligations the venue records against `reserve`.
    /// @return price The venue's oracle price for `reserve`, 8 decimals, `1e8` at peg.
    /// @return redeemableLiquidity Underlying actually available to redeem right now.
    /// @return totalSupplied Everything supplied to the reserve, deficit included. The denominator
    ///         the deficit is judged against: a deficit is only meaningful as a share of the
    ///         reserve it sits in, and an absolute figure cannot distinguish a rounding artefact
    ///         from an insolvency.
    function observeReserve(address reserve, address aToken)
        external
        view
        returns (
            uint256 deficit,
            uint256 price,
            uint256 redeemableLiquidity,
            uint256 totalSupplied
        );

    /// @notice Supply `assets` to the venue, pulled from the caller.
    function deposit(uint256 assets) external returns (uint256 supplied);

    /// @notice Redeem `assets` from the venue and send them to `to`.
    function withdraw(uint256 assets, address to) external returns (uint256 redeemed);
}
