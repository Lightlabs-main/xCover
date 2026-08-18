// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoverPool
/// @notice Underwriting capital for xCover: holds the assets that pay claims, tracks how much
///         cover has been promised against them, and distributes premium to capital providers.
///
/// @dev The contract exists to satisfy one property, stated in SPEC §4.1:
///
///          capital >= outstandingCover
///
///      Full collateralization, not fractional. The risks in this book are perfectly correlated —
///      one exploit triggers every policy at once — and the book is small, so the law of large
///      numbers that justifies fractional reserving does not apply. Full backing is the only
///      honest choice, and it means the pool cannot become insolvent.
///
///      Two further properties are proven alongside it by the invariant suite:
///
///          asset.balanceOf(pool) >= capital        the accounting is backed by real tokens
///          sum(active cover) == outstandingCover   the obligation total has not drifted
///
///      The middle property catches what the first cannot see: an internal counter drifting away
///      from the tokens actually held.
interface ICoverPool {
    /// @notice Capital was supplied by a provider in exchange for shares.
    event CapitalDeposited(address indexed provider, uint256 assets, uint256 shares);

    /// @notice Capital was withdrawn by a provider, burning shares.
    event CapitalWithdrawn(address indexed provider, uint256 assets, uint256 shares);

    /// @notice Cover was promised against a policy, locking capital behind it.
    event CoverReserved(uint256 indexed policyId, uint256 amount);

    /// @notice A policy's obligation ended without a payout (expiry or cancellation).
    event CoverReleased(uint256 indexed policyId, uint256 amount);

    /// @notice Premium was paid into the pool, raising capital for every provider.
    event PremiumAccrued(address indexed payer, uint256 amount);

    /// @notice A triggered claim was settled from pool capital.
    event ClaimPaid(uint256 indexed policyId, address indexed to, uint256 amount);

    /// @notice Reserving this cover would leave promises exceeding capital. Issuance reverts
    ///         rather than queueing or partially filling (SPEC §4.1).
    error InsufficientFreeCapital(uint256 requested, uint256 available);

    /// @notice Withdrawing would release capital that is locked behind active cover.
    error CapitalLocked(uint256 requested, uint256 free);

    /// @notice This policy already holds a reserved obligation.
    error CoverAlreadyReserved(uint256 policyId);

    /// @notice This policy holds no reserved obligation.
    error NoCoverReserved(uint256 policyId);

    /// @notice A payout may never exceed the cover reserved for that policy.
    error PayoutExceedsCover(uint256 requested, uint256 reserved);

    /// @notice Zero-valued calls are rejected rather than silently succeeding.
    error ZeroAmount();

    /// @notice The pool was fully paid out while legacy provider shares still exist. Those shares
    ///        must be burned before a new capital epoch can start, or the new depositor would be
    ///        given an incorrect fraction of the pool.
    error CapitalFullyPaidOut();

    /// @notice Total assets held on behalf of capital providers, in the asset's own decimals.
    function capital() external view returns (uint256);

    /// @notice Sum of the payout obligations of every policy with cover currently reserved.
    function outstandingCover() external view returns (uint256);

    /// @notice Capital not locked behind active cover: `capital - outstandingCover`.
    /// @dev The bound on withdrawals. Locked capital is the mechanism, not a UX wart.
    function freeCapital() external view returns (uint256);

    /// @notice Cover reserved against a single policy, zero once released or paid.
    function coverOf(uint256 policyId) external view returns (uint256);

    /// @notice Supply capital and receive provider shares.
    function depositCapital(uint256 assets) external returns (uint256 shares);

    /// @notice Burn provider shares and withdraw capital, bounded by `freeCapital()`.
    function withdrawCapital(uint256 shares) external returns (uint256 assets);

    /// @notice Promise `amount` of cover against `policyId`, locking capital behind it.
    /// @dev The only path that may increase `outstandingCover`. Reverts if it would breach the
    ///      solvency invariant. Blocked while issuance is paused; claims and withdrawals are not.
    function reserveCover(uint256 policyId, uint256 amount) external;

    /// @notice End a policy's obligation without a payout, freeing the capital behind it.
    function releaseCover(uint256 policyId) external;

    /// @notice Pay premium into the pool. Raises capital without raising obligations.
    function accruePremium(uint256 amount) external;

    /// @notice Settle a triggered claim, reducing capital and the obligation together.
    function payClaim(uint256 policyId, address to, uint256 amount) external;
}
