// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";

/// @title CoverPool
/// @notice Underwriting capital for xCover. Holds the assets that pay claims, tracks how much
///         cover has been promised against them, and distributes premium to capital providers.
///
/// @dev The whole contract exists to hold one line true:
///
///          capital >= outstandingCover
///
///      That is enforced structurally rather than by repeated assertion. `_reserve` is the only
///      function in the contract that can increase `outstandingCover`, and the check lives inside
///      it. A future contributor cannot add a path that skips the check, because there is no other
///      path to add it to.
///
///      Everything else is arranged so the invariant cannot be reached from the other side:
///
///      - `withdrawCapital` is bounded by `freeCapital()`, never by share balance alone.
///      - `payClaim` reduces `capital` and `outstandingCover` by the same amount, in one step.
///      - `accruePremium` raises `capital` without touching obligations, so it can only widen the
///        margin.
///      - `capital` is only ever credited from a measured transfer in, so a direct token donation
///        to this address is not counted as capital and cannot inflate underwriting headroom.
///
///      Pausing blocks issuance only. Withdrawals and claim settlement are deliberately outside
///      `whenNotPaused` — a user's ability to exit or be paid must not depend on anyone's
///      cooperation (SPEC §4.7).
contract CoverPool is ICoverPool, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /// @notice May reserve and release cover. Held by xCoverVault.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice May settle a triggered claim. Held by ClaimResolver, which is deterministic.
    bytes32 public constant CLAIM_ROLE = keccak256("CLAIM_ROLE");

    /// @notice May pause new issuance. Nothing else — see the contract note above.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Cover is fully collateralized: 100%, not fractional (SPEC §4.1).
    uint256 public constant RESERVE_RATIO_BPS = 10_000;

    /// @notice The underwriting asset. USDT at launch.
    IERC20 public immutable asset;

    /// @inheritdoc ICoverPool
    uint256 public capital;

    /// @inheritdoc ICoverPool
    uint256 public outstandingCover;

    /// @notice Total provider shares issued.
    uint256 public totalShares;

    /// @notice Provider share balances.
    mapping(address => uint256) public sharesOf;

    /// @inheritdoc ICoverPool
    mapping(uint256 => uint256) public coverOf;

    constructor(IERC20 asset_, address admin) {
        asset = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // --- views ----------------------------------------------------------------------------

    /// @inheritdoc ICoverPool
    function freeCapital() public view returns (uint256) {
        // Never underflows: the invariant this contract enforces is exactly that it cannot.
        return capital - outstandingCover;
    }

    /// @notice Assets a provider could withdraw right now, after the free-capital bound.
    function maxWithdraw(address provider) external view returns (uint256) {
        return Math.min(_toAssets(sharesOf[provider]), freeCapital());
    }

    function _toAssets(uint256 shares) internal view returns (uint256) {
        if (totalShares == 0) return 0;
        return Math.mulDiv(shares, capital, totalShares);
    }

    // --- capital providers ----------------------------------------------------------------

    /// @inheritdoc ICoverPool
    /// @dev Shares are priced off `capital`, which is credited from the amount actually received
    ///      rather than the amount requested. A fee-on-transfer or rebasing asset would otherwise
    ///      let the pool believe it holds more than it does — the precise drift that would break
    ///      the balance-backs-capital property.
    function depositCapital(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = asset.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        // First deposit, or a pool whose capital was fully paid out in claims: price 1:1 rather
        // than dividing by zero.
        shares = (totalShares == 0 || capital == 0) ? received : Math.mulDiv(received, totalShares, capital);
        if (shares == 0) revert ZeroAmount();

        capital += received;
        totalShares += shares;
        sharesOf[msg.sender] += shares;

        emit CapitalDeposited(msg.sender, received, shares);
    }

    /// @inheritdoc ICoverPool
    /// @dev Not `whenNotPaused`. Capital locked behind active cover stays locked until those
    ///      policies end; that is the mechanism, and the UI shows locked against free explicitly.
    function withdrawCapital(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert CapitalLocked(shares, held);

        // Rounds down, so the pool never pays out more than the share is worth. The dust stays
        // with the remaining providers rather than leaking out of the accounting.
        assets = _toAssets(shares);
        uint256 free = freeCapital();
        if (assets > free) revert CapitalLocked(assets, free);

        sharesOf[msg.sender] = held - shares;
        totalShares -= shares;
        capital -= assets;

        emit CapitalWithdrawn(msg.sender, assets, shares);

        // Checks, effects, interactions: state is settled before the token moves.
        asset.safeTransfer(msg.sender, assets);
    }

    /// @inheritdoc ICoverPool
    /// @dev Permissionless by design. Premium arrives from the vault streaming a position's yield,
    ///      but anyone may top the pool up; it can only improve solvency.
    function accruePremium(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        capital += received;
        emit PremiumAccrued(msg.sender, received);
    }

    // --- underwriting ---------------------------------------------------------------------

    /// @inheritdoc ICoverPool
    function reserveCover(uint256 policyId, uint256 amount)
        external
        onlyRole(VAULT_ROLE)
        whenNotPaused
    {
        _reserve(policyId, amount);
    }

    /// @dev The single chokepoint. The only code in this contract that raises `outstandingCover`,
    ///      and therefore the only place the solvency check needs to exist.
    function _reserve(uint256 policyId, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (coverOf[policyId] != 0) revert CoverAlreadyReserved(policyId);

        uint256 free = freeCapital();
        if (amount > free) revert InsufficientFreeCapital(amount, free);

        coverOf[policyId] = amount;
        outstandingCover += amount;

        emit CoverReserved(policyId, amount);
    }

    /// @inheritdoc ICoverPool
    function releaseCover(uint256 policyId) external onlyRole(VAULT_ROLE) {
        uint256 reserved = coverOf[policyId];
        if (reserved == 0) revert NoCoverReserved(policyId);

        // Cleared before the subtraction, so a re-entrant release finds nothing to release.
        coverOf[policyId] = 0;
        outstandingCover -= reserved;

        emit CoverReleased(policyId, reserved);
    }

    /// @inheritdoc ICoverPool
    /// @dev Not `whenNotPaused`. A valid claim does not wait on an administrator.
    ///      Capital and the obligation fall together, so the margin between them never narrows on
    ///      a payout — a claim can empty the pool but cannot make it insolvent.
    function payClaim(uint256 policyId, address to, uint256 amount) external onlyRole(CLAIM_ROLE) {
        uint256 reserved = coverOf[policyId];
        if (reserved == 0) revert NoCoverReserved(policyId);
        if (amount > reserved) revert PayoutExceedsCover(amount, reserved);

        // The obligation ends in full, whether or not the payout used all of it: a partial
        // settlement releases the remainder rather than leaving it locked forever.
        coverOf[policyId] = 0;
        outstandingCover -= reserved;
        capital -= amount;

        emit ClaimPaid(policyId, to, amount);

        asset.safeTransfer(to, amount);
    }

    // --- administration -------------------------------------------------------------------

    /// @notice Halt new issuance. Withdrawals and claims are unaffected, by construction.
    function pauseIssuance() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume issuance.
    function unpauseIssuance() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
