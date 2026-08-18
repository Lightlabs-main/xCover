// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IYieldVenue} from "../interfaces/IYieldVenue.sol";
import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {IAaveOracle} from "../interfaces/IAaveOracle.sol";

/// @title AaveV3Venue
/// @notice Supplies covered positions to the real Aave V3 Pool on X Layer mainnet.
///
/// @dev **Whose money this is.** The assets here are the depositor's own position — the thing
///      being covered. They are not `CoverPool` capital. That distinction is the reason this
///      contract may hold an Aave approval and `CoverPool` may not: underwriting capital supplied
///      to the covered reserve would lose value at precisely the moment claims trigger, which is
///      the reflexivity failure that broke first-generation cover protocols. Keeping the two in
///      separate contracts makes that separation structural instead of a rule someone must
///      remember.
///
///      **No deficit surface.** This contract exposes nothing that could induce, increase, or
///      repair a reserve deficit. The claim trigger reads Aave's state; it can never be written
///      to from here. There is a test asserting the absence, because the absence is the point:
///      a venue that could move the trigger it is measured against would make every claim
///      suspect.
///
///      Balances are read live from the aToken rather than tracked internally. aTokens rebase as
///      interest accrues, so any internal counter would drift from the truth by design, and the
///      truth is what a withdrawal has to settle against.
contract AaveV3Venue is IYieldVenue, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice May supply and redeem. Held by xCoverVault.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @inheritdoc IYieldVenue
    IERC20 public immutable asset;

    /// @notice The Aave V3 Pool this venue supplies to.
    IAaveV3Pool public immutable aavePool;

    /// @notice The aToken received for supplying `asset`. Rebases as interest accrues.
    IERC20 public immutable aToken;

    /// @notice Aave's own price oracle. Read-only from here.
    IAaveOracle public immutable oracle;

    constructor(
        IERC20 asset_,
        IAaveV3Pool aavePool_,
        IERC20 aToken_,
        IAaveOracle oracle_,
        address admin
    ) {
        asset = asset_;
        aavePool = aavePool_;
        aToken = aToken_;
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IYieldVenue
    function venueName() external pure returns (string memory) {
        return "aave-v3/xlayer-mainnet";
    }

    /// @inheritdoc IYieldVenue
    function hasYieldSource() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IYieldVenue
    /// @dev Read live from the aToken: the balance grows as interest accrues, and an internal
    ///      counter would understate what the depositor is owed.
    function totalAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @inheritdoc IYieldVenue
    function deposit(uint256 assets) external onlyRole(VAULT_ROLE) returns (uint256 supplied) {
        if (assets == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        // Approval is granted for exactly this supply and consumed by it, rather than left
        // standing. Aave is a live upgradeable contract; a permanent unlimited allowance to
        // something that can be upgraded beneath you is an unnecessary standing risk.
        asset.forceApprove(address(aavePool), assets);
        aavePool.supply(address(asset), assets, address(this), 0);
        asset.forceApprove(address(aavePool), 0);

        emit Supplied(assets);
        return assets;
    }

    /// @inheritdoc IYieldVenue
    /// @dev Reverts if Aave returns less than requested. A partial redemption silently treated as
    ///      whole would leave a user short and the accounting wrong; the caller is told instead.
    function withdraw(uint256 assets, address to)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 redeemed)
    {
        if (assets == 0) revert ZeroAmount();

        redeemed = aavePool.withdraw(address(asset), assets, to);
        if (redeemed < assets) revert InsufficientVenueLiquidity(assets, redeemed);

        emit Redeemed(redeemed, to);
    }

    /// @inheritdoc IYieldVenue
    /// @dev Three pass-through reads of live Aave state. The `aToken_` argument is retained for
    ///      interface compatibility but deliberately ignored: liquidity and the denominator must
    ///      come from this venue's immutable aToken, not from an arbitrary address chosen by the
    ///      permissionless observer. Nothing is cached, and there is deliberately no counterpart
    ///      anywhere in this contract that can write any of the three — see the no-deficit-surface
    ///      note above.
    function observeReserve(address reserve, address)
        external
        view
        returns (
            uint256 deficit,
            uint256 price,
            uint256 redeemableLiquidity,
            uint256 totalSupplied
        )
    {
        return (
            aavePool.getReserveDeficit(reserve),
            oracle.getAssetPrice(reserve),
            IERC20(reserve).balanceOf(address(aToken)),
            // The aToken's total supply is everything supplied to the reserve, so it is the
            // denominator the deficit has to be judged against. Read live: it rebases with
            // interest, and a stale denominator would misstate the share.
            aToken.totalSupply()
        );
    }

    /// @notice The reserve deficit Aave records for the covered asset — the primary claim trigger.
    /// @dev A pass-through read, exposed here so the resolver reads the same source the venue
    ///      supplies to. There is deliberately no counterpart that writes it.
    function reserveDeficit() external view returns (uint256) {
        return aavePool.getReserveDeficit(address(asset));
    }
}
