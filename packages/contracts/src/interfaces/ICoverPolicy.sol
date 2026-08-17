// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoverPolicy
/// @notice ERC-721 cover positions and their lifecycle (SPEC §4.2).
///
/// @dev The token is the position. Each policy holds a payout obligation reserved against
///      `CoverPool`, and every terminal transition releases that reservation exactly once:
///
///          Quoted ──mint──────► Active
///          Active ──expiry────► Expired      obligation released
///          Active ──trigger───► Claimable    obligation retained, awaiting settlement
///          Claimable ──claim──► Paid         obligation settled from capital
///          Active ──cancel────► Cancelled    obligation released, premium refunded pro-rata
interface ICoverPolicy {
    enum PolicyState {
        None,
        Active,
        Expired,
        Claimable,
        Paid,
        Cancelled
    }

    struct Policy {
        address reserve; // covered asset — USDT at launch
        uint256 coverAmount; // payout ceiling, in the reserve's own decimals
        uint64 startBlock; // the waiting period is measured from here
        uint64 endBlock;
        uint256 premiumRateRay; // per-block rate, taken from the signed quote
        bytes32 quoteHash; // links to the PricingRegistry record
        bytes32 termsHash; // hash of the covered-events terms as of mint
        PolicyState state;
    }

    event PolicyMinted(
        uint256 indexed policyId,
        address indexed holder,
        address indexed reserve,
        uint256 coverAmount,
        uint64 startBlock,
        uint64 endBlock,
        bytes32 quoteHash,
        bytes32 termsHash
    );
    event PolicyExpired(uint256 indexed policyId);
    event PolicyCancelled(uint256 indexed policyId);
    event PolicyClaimable(uint256 indexed policyId);
    event PolicyPaid(uint256 indexed policyId, uint256 amount);

    /// @notice The policy is not in a state this transition is defined for.
    error InvalidState(uint256 policyId, PolicyState actual, PolicyState expected);
    /// @notice This policy id has never been minted.
    error UnknownPolicy(uint256 policyId);
    /// @notice The policy term has not ended yet.
    error NotExpired(uint256 policyId, uint64 endBlock);
    /// @notice Cover has not activated: the waiting period has not elapsed (SPEC §4.2).
    error WaitingPeriodActive(uint256 policyId, uint64 activeFromBlock);
    /// @notice The policy term is outside the permitted bounds.
    error InvalidTerm(uint64 startBlock, uint64 endBlock);
    /// @notice New cover written for this reserve today would exceed the daily cap.
    error DailyCapExceeded(address reserve, uint256 requested, uint256 remaining);
    /// @notice Zero-valued cover is rejected rather than silently minted.
    error ZeroAmount();

    function policies(uint256 policyId) external view returns (Policy memory);

    /// @notice True only while the policy is Active, past its waiting period, and within term.
    /// @dev The single question ClaimResolver asks before evaluating a trigger.
    function isCoverActive(uint256 policyId) external view returns (bool);

    /// @notice Block from which this policy's cover is live.
    function activeFromBlock(uint256 policyId) external view returns (uint64);
}
