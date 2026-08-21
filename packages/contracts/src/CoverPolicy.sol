// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICoverPolicy} from "./interfaces/ICoverPolicy.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";

/// @title CoverPolicy
/// @notice ERC-721 cover positions. The token is the position (SPEC §4.2), and is non-transferable
///      in this build because the companion vault position is address-keyed.
///
/// @dev Every policy is minted with capital already locked behind it: `mintPolicy` calls
///      `CoverPool.reserveCover` in the same transaction, and the pool reverts if that would
///      breach solvency. There is no path that creates an obligation without backing it, because
///      minting and reserving are the same call.
///
///      The mirror of that rule governs the exits. `Expired`, `Cancelled` and `Paid` are terminal,
///      and each releases or settles the pool reservation exactly once. State is written before
///      the pool is called, so a re-entrant transition finds the policy already terminal and
///      reverts on the state check rather than releasing the same obligation twice.
///
///      Two adverse-selection controls live here rather than in the pricing model, because a
///      control the model can be talked out of is not a control:
///
///      - **Waiting period.** Cover does not activate until `startBlock + waitingPeriodBlocks`.
///        Without it, anyone who sees trouble coming buys cover immediately before the payout.
///      - **Daily cap per reserve.** New cover written per reserve per day is bounded, so the
///        same insight cannot be scaled up arbitrarily within a single day.
contract CoverPolicy is ICoverPolicy, ERC721, AccessControl {
    using Strings for uint256;
    /// @notice May mint policies and end them without a payout. Held by xCoverVault.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice May move a policy to Claimable and then Paid. Held by ClaimResolver, which is
    ///         deterministic and has no discretion.
    bytes32 public constant CLAIM_ROLE = keccak256("CLAIM_ROLE");

    /// @notice May pause new issuance only — see `CoverPool` for why that stops at issuance.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice The pool holding the capital behind every policy minted here.
    ICoverPool public immutable pool;

    /// @notice Blocks between `startBlock` and cover activating.
    uint64 public immutable waitingPeriodBlocks;

    /// @notice Ceiling on new cover written per reserve per day, in the reserve's decimals.
    uint256 public immutable dailyCoverCap;

    /// @notice Direct policy transfers are disabled because xCoverVault positions are address-keyed.
    ///      A future transferable design must move the policy and its vault shares atomically.
    error PositionTransfersDisabled();

    uint256 internal _nextPolicyId = 1;

    mapping(uint256 => Policy) internal _policies;

    /// @notice Cover written per reserve, per day index (`block.timestamp / 1 days`).
    mapping(address => mapping(uint256 => uint256)) public coverWrittenOnDay;

    constructor(
        ICoverPool pool_,
        uint64 waitingPeriodBlocks_,
        uint256 dailyCoverCap_,
        address admin
    ) ERC721("xCover Policy", "XCOVER") {
        pool = pool_;
        waitingPeriodBlocks = waitingPeriodBlocks_;
        dailyCoverCap = dailyCoverCap_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // --- views ----------------------------------------------------------------------------

    /// @inheritdoc ICoverPolicy
    function policies(uint256 policyId) external view returns (Policy memory) {
        Policy memory p = _policies[policyId];
        if (p.state == PolicyState.None) revert UnknownPolicy(policyId);
        return p;
    }

    /// @inheritdoc ICoverPolicy
    function nextPolicyId() external view returns (uint256) {
        return _nextPolicyId;
    }

    /// @inheritdoc ICoverPolicy
    function activeFromBlock(uint256 policyId) public view returns (uint64) {
        Policy storage p = _policies[policyId];
        if (p.state == PolicyState.None) revert UnknownPolicy(policyId);
        return p.startBlock + waitingPeriodBlocks;
    }

    /// @inheritdoc ICoverPolicy
    function isCoverActive(uint256 policyId) public view returns (bool) {
        Policy storage p = _policies[policyId];
        return p.state == PolicyState.Active && block.number >= p.startBlock + waitingPeriodBlocks
            && block.number <= p.endBlock;
    }

    /// @notice Cover still writable for `reserve` today, before the daily cap binds.
    function remainingDailyCapacity(address reserve) public view returns (uint256) {
        uint256 written = coverWrittenOnDay[reserve][block.timestamp / 1 days];
        return written >= dailyCoverCap ? 0 : dailyCoverCap - written;
    }

    /// @notice The day bucket the cap is measured over.
    function currentDay() external view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Total payout obligation currently reserved for this policy, per the pool.
    function reservedCover(uint256 policyId) external view returns (uint256) {
        return pool.coverOf(policyId);
    }

    /// @notice Fully on-chain metadata for wallets, explorers and policy viewers.
    /// @dev The SVG and JSON are generated from current policy state, so terminal lifecycle
    ///      transitions are reflected without an off-chain metadata server or mutable base URI.
    function tokenURI(uint256 policyId) public view override returns (string memory) {
        _requireOwned(policyId);
        Policy storage p = _policies[policyId];
        string memory id = policyId.toString();
        string memory stateLabel = _stateLabel(p.state);
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 720">',
            '<rect width="720" height="720" rx="48" fill="#081a38"/>',
            '<path d="M0 520L720 250V720H0Z" fill="#1267ff" opacity=".28"/>',
            '<text x="60" y="105" fill="#80adff" font-family="monospace" font-size="24">X LAYER / AAVE V3</text>',
            '<text x="60" y="210" fill="white" font-family="sans-serif" font-size="72" font-weight="700">xCover</text>',
            '<text x="60" y="285" fill="#80adff" font-family="monospace" font-size="32">POLICY NFT #', id, '</text>',
            '<rect x="60" y="360" width="600" height="110" rx="20" fill="#102b59" stroke="#4386ff"/>',
            '<text x="90" y="405" fill="#80adff" font-family="monospace" font-size="20">LIFECYCLE</text>',
            '<text x="90" y="448" fill="white" font-family="sans-serif" font-size="32" font-weight="600">', stateLabel, '</text>',
            '<text x="60" y="575" fill="white" font-family="monospace" font-size="22">COVER ', p.coverAmount.toString(), ' USDT UNITS</text>',
            '<text x="60" y="620" fill="#80adff" font-family="monospace" font-size="18">START ', uint256(p.startBlock).toString(), ' / END ', uint256(p.endBlock).toString(), '</text>',
            '<text x="60" y="665" fill="#80adff" font-family="monospace" font-size="18">ON-CHAIN / NON-TRANSFERABLE</text>',
            '</svg>'
        );
        string memory json = string.concat(
            '{"name":"xCover Policy #', id,
            '","description":"Non-transferable, fully backed Aave V3 depositor cover on X Layer. Policy terms and lifecycle are enforced on-chain.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes":[',
            '{"trait_type":"Lifecycle","value":"', stateLabel, '"},',
            '{"trait_type":"Covered amount (USDT units)","value":"', p.coverAmount.toString(), '"},',
            '{"display_type":"number","trait_type":"Start block","value":', uint256(p.startBlock).toString(), '},',
            '{"display_type":"number","trait_type":"Active from block","value":', uint256(p.startBlock + waitingPeriodBlocks).toString(), '},',
            '{"display_type":"number","trait_type":"End block","value":', uint256(p.endBlock).toString(), '}',
            ']}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _stateLabel(PolicyState state) internal pure returns (string memory) {
        if (state == PolicyState.Active) return "Active";
        if (state == PolicyState.Expired) return "Expired";
        if (state == PolicyState.Claimable) return "Claimable";
        if (state == PolicyState.Paid) return "Paid";
        if (state == PolicyState.Cancelled) return "Cancelled";
        return "Unknown";
    }

    // --- issuance -------------------------------------------------------------------------

    /// @notice Mint a policy and lock the capital behind it in the same transaction.
    /// @dev Reverts rather than partially filling if the pool lacks free capital, if the daily cap
    ///      binds, or if the term is malformed. A policy that exists is a policy that is backed.
    function mintPolicy(
        address to,
        address reserve,
        uint256 coverAmount,
        uint64 endBlock,
        uint256 premiumRateRay,
        bytes32 quoteHash,
        bytes32 termsHash
    ) external onlyRole(VAULT_ROLE) returns (uint256 policyId) {
        if (coverAmount == 0) revert ZeroAmount();

        uint64 startBlock = uint64(block.number);
        // The term must outlast the waiting period, or the policy expires without ever having
        // provided cover — a position the buyer would be paying for and never protected by.
        if (endBlock <= startBlock + waitingPeriodBlocks) revert InvalidTerm(startBlock, endBlock);

        uint256 remaining = remainingDailyCapacity(reserve);
        if (coverAmount > remaining) revert DailyCapExceeded(reserve, coverAmount, remaining);
        coverWrittenOnDay[reserve][block.timestamp / 1 days] += coverAmount;

        policyId = _nextPolicyId++;
        _policies[policyId] = Policy({
            reserve: reserve,
            coverAmount: coverAmount,
            startBlock: startBlock,
            endBlock: endBlock,
            premiumRateRay: premiumRateRay,
            quoteHash: quoteHash,
            termsHash: termsHash,
            state: PolicyState.Active
        });

        // Lock the capital before the token exists. If the pool cannot back this cover the whole
        // transaction reverts and no policy is created.
        pool.reserveCover(policyId, coverAmount);

        _safeMint(to, policyId);

        emit PolicyMinted(
            policyId, to, reserve, coverAmount, startBlock, endBlock, quoteHash, termsHash
        );
    }

    // --- lifecycle ------------------------------------------------------------------------

    /// @notice End a policy whose term has run out, freeing the capital behind it.
    /// @dev Permissionless: expiry is a fact about the block number, not a decision. Anyone may
    ///      settle it, and capital providers have every reason to.
    function expire(uint256 policyId) external {
        Policy storage p = _policies[policyId];
        _requireState(policyId, p.state, PolicyState.Active);
        if (block.number <= p.endBlock) revert NotExpired(policyId, p.endBlock);

        p.state = PolicyState.Expired;
        pool.releaseCover(policyId);

        emit PolicyExpired(policyId);
    }

    /// @notice Cancel an active policy, releasing its capital.
    /// @dev Pro-rata premium refund is computed and paid by the vault, which holds the streamed
    ///      premium; this contract's responsibility ends at releasing the obligation.
    function cancel(uint256 policyId) external onlyRole(VAULT_ROLE) {
        Policy storage p = _policies[policyId];
        _requireState(policyId, p.state, PolicyState.Active);

        p.state = PolicyState.Cancelled;
        pool.releaseCover(policyId);

        emit PolicyCancelled(policyId);
    }

    /// @notice Mark a policy claimable after a trigger has been evaluated as met.
    /// @dev Only ClaimResolver may call this, and it holds no discretion: it reads chain state
    ///      against the thresholds fixed in `termsHash` and reports. The waiting-period check is
    ///      repeated here rather than trusted from the caller, so cover that never activated
    ///      cannot be paid out.
    function markClaimable(uint256 policyId) external onlyRole(CLAIM_ROLE) {
        Policy storage p = _policies[policyId];
        _requireState(policyId, p.state, PolicyState.Active);

        uint64 activeFrom = p.startBlock + waitingPeriodBlocks;
        if (block.number < activeFrom) revert WaitingPeriodActive(policyId, activeFrom);

        p.state = PolicyState.Claimable;
        emit PolicyClaimable(policyId);
    }

    /// @notice Record that a claimable policy has been settled.
    /// @dev Called by ClaimResolver in the same transaction as `CoverPool.payClaim`.
    function markPaid(uint256 policyId, uint256 amount) external onlyRole(CLAIM_ROLE) {
        Policy storage p = _policies[policyId];
        _requireState(policyId, p.state, PolicyState.Claimable);

        p.state = PolicyState.Paid;
        emit PolicyPaid(policyId, amount);
    }

    function _requireState(uint256 policyId, PolicyState actual, PolicyState expected)
        internal
        pure
    {
        if (actual == PolicyState.None) revert UnknownPolicy(policyId);
        if (actual != expected) revert InvalidState(policyId, actual, expected);
    }

    /// @dev Minting and burning remain available to the lifecycle. A live transfer would move the
    /// ERC-721 owner without moving xCoverVault's address-keyed `positions` entry, leaving either
    /// the buyer unable to exit or the seller able to cancel the buyer's cover.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert PositionTransfersDisabled();
        return super._update(to, tokenId, auth);
    }

    // --- ERC165 ---------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
