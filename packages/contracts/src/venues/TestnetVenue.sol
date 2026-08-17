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

    /// @notice May induce a deficit or move the reported price, so a judge can trigger a claim.
    /// @dev Exists on this contract only. `AaveV3Venue` has no equivalent and no such surface at
    ///      all; a fork test asserts the selector is absent from its bytecode.
    bytes32 public constant DEMO_ROLE = keccak256("DEMO_ROLE");

    /// @notice A stablecoin at peg, at the oracle's 8 decimals.
    uint256 public constant PEG_PRICE = 1e8;

    /// @notice Where assets written off by `induceDeficit` go.
    /// @dev They leave this contract for real rather than being subtracted from a counter, so the
    ///      shortfall the resolver reads is a shortfall that genuinely exists on chain.
    address public constant DEFICIT_SINK = address(0xdEaD);

    /// @inheritdoc IYieldVenue
    IERC20 public immutable asset;

    /// @notice Assets held on deposit. One to one: there is nothing here to accrue.
    uint256 public deposited;

    /// @notice Obligations this venue can no longer cover, in `asset` decimals.
    /// @dev Deliberately does **not** reduce `deposited`. That is what a deficit is: the venue still
    ///      owes depositors the full amount and no longer holds it. Aave models it the same way —
    ///      aToken balances stand while `getReserveDeficit` records the hole.
    uint256 public deficit;

    /// @notice The venue's price for `asset`, 8 decimals. Starts at peg.
    uint256 public reportedPrice = PEG_PRICE;

    /// @notice A deficit was written off against the venue's holdings.
    event DeficitInduced(uint256 amount, uint256 totalDeficit);
    /// @notice The reported price moved.
    event PriceReported(uint256 price);

    /// @notice This venue holds exactly one asset; `reserve` must be it.
    error UnknownReserve(address reserve);
    /// @notice Cannot write off more than is actually held.
    error DeficitExceedsHoldings(uint256 requested, uint256 held);

    constructor(IERC20 asset_, address admin) {
        asset = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEMO_ROLE, admin);
    }

    // --- claim trigger source -------------------------------------------------------------

    /// @inheritdoc IYieldVenue
    /// @dev Read live from this contract's own real state: the deficit that has been written off,
    ///      the price it reports, and the underlying it actually still holds. `aToken` is unused —
    ///      there is no interest-bearing wrapper here, the venue holds the underlying itself.
    function observeReserve(address reserve, address)
        external
        view
        returns (uint256, uint256, uint256)
    {
        if (reserve != address(asset)) revert UnknownReserve(reserve);
        return (deficit, reportedPrice, asset.balanceOf(address(this)));
    }

    /// @notice Write off `amount` of the venue's holdings, creating a real deficit.
    /// @dev The point of the testnet deployment (SPEC §3.5): a judge calls this and watches
    ///      `ClaimResolver` sample the window, fire, and settle a payout in their own browser,
    ///      against a deployed chain. It moves real tokens out of this contract, so both the
    ///      deficit trigger and the redemption-failure trigger see a shortfall that is actually
    ///      there. **Absent from `AaveV3Venue` entirely** — mainnet has no such function.
    function induceDeficit(address reserve, uint256 amount) external onlyRole(DEMO_ROLE) {
        if (reserve != address(asset)) revert UnknownReserve(reserve);
        if (amount == 0) revert ZeroAmount();

        uint256 held = asset.balanceOf(address(this));
        if (amount > held) revert DeficitExceedsHoldings(amount, held);

        deficit += amount;
        emit DeficitInduced(amount, deficit);

        asset.safeTransfer(DEFICIT_SINK, amount);
    }

    /// @notice Set the price this venue reports for `asset`, 8 decimals.
    /// @dev Testnet has no price oracle to read, so the depeg trigger needs a price source that
    ///      exists. This is that source, and it is honest about being one: the value is this
    ///      venue's own state, visible on the explorer, not a fabricated reading dressed up as an
    ///      external oracle. Mainnet reads Aave's oracle through `AaveV3Venue` instead.
    function setReportedPrice(address reserve, uint256 price) external onlyRole(DEMO_ROLE) {
        if (reserve != address(asset)) revert UnknownReserve(reserve);
        reportedPrice = price;
        emit PriceReported(price);
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
