// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IYieldVenue} from "../interfaces/IYieldVenue.sol";

/// @title TestnetVenue
/// @notice Custody-only venue for X Layer testnet, where Aave V3 does not exist.
///
/// @dev **This is not a mock of Aave, and must never be described as one.** Verified on
///      2026-08-17: both `POOL` and `POOL_ADDRESSES_PROVIDER` have empty code on X Layer testnet.
///      There is no lending market to supply to, so this contract does the only honest thing
///      available — it custodies the deposit and returns exactly what was put in.
///
///      **It pays no yield, and it does not pretend to.** `hasYieldSource()` returns false and
///      `venueName()` says `custody-only/xlayer-testnet`, so any UI or deployment record reading
///      this contract states plainly what backs it. A testnet demo showing an APY that no venue
///      is producing would be a fabricated number presented as protocol state, which is the exact
///      failure mode the project rules forbid.
///
///      What testnet is genuinely for: exercising the deposit → policy → trigger → payout path
///      end to end so a judge can run a claim themselves. None of that needs yield. Premium on
///      testnet is paid from the depositor's balance rather than streamed from accrual, and the
///      deployment record says so.
contract TestnetVenue is IYieldVenue, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice May supply and redeem. Held by xCoverVault.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @inheritdoc IYieldVenue
    IERC20 public immutable asset;

    /// @notice Assets held on deposit. One to one: there is nothing here to accrue.
    uint256 public deposited;

    constructor(IERC20 asset_, address admin) {
        asset = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IYieldVenue
    function venueName() external pure returns (string memory) {
        return "custody-only/xlayer-testnet";
    }

    /// @inheritdoc IYieldVenue
    /// @dev False, and deliberately so. Aave is not deployed on X Layer testnet.
    function hasYieldSource() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IYieldVenue
    function totalAssets() public view returns (uint256) {
        return deposited;
    }

    /// @inheritdoc IYieldVenue
    function deposit(uint256 assets) external onlyRole(VAULT_ROLE) returns (uint256 supplied) {
        if (assets == 0) revert ZeroAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        supplied = asset.balanceOf(address(this)) - before;
        if (supplied == 0) revert ZeroAmount();

        deposited += supplied;
        emit Supplied(supplied);
    }

    /// @inheritdoc IYieldVenue
    function withdraw(uint256 assets, address to)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 redeemed)
    {
        if (assets == 0) revert ZeroAmount();
        if (assets > deposited) revert InsufficientVenueLiquidity(assets, deposited);

        deposited -= assets;
        emit Redeemed(assets, to);

        asset.safeTransfer(to, assets);
        return assets;
    }
}
