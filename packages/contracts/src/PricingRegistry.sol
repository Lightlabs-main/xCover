// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title PricingRegistry
/// @notice The on-chain record of every pricing decision the agent makes — quotes and refusals
///         alike (SPEC §4.5).
///
/// @dev This contract is where the separation between the model and the money is made
///      structural. The agent's key can do exactly one thing here: sign a decision. It cannot
///      move funds, mint a policy, or influence a claim, because this contract has no function
///      that does any of those things and holds no capital to move.
///
///      **Refusals are recorded, not discarded.** A `DECLINE_TO_QUOTE` is a successful outcome
///      with a permanent on-chain record, identical in standing to a quote and distinguished only
///      by `declined`. An agent that always quotes is an agent that has not understood the
///      problem, and a registry that only stores quotes cannot tell you whether it did.
///
///      **The signature, not the transaction, is the authority.** Decisions are signed off-chain
///      under EIP-712 and may be submitted by anyone; authority comes from the recovered signer
///      holding `PRICER_ROLE`. The pricing key therefore never needs to hold gas, never sends a
///      transaction, and its compromise exposes nothing beyond the ability to sign quotes — which
///      the pool's solvency check and the resolver's determinism already bound.
///
///      **Every decision commits to its own reasoning.** `decisionHash` is the hash of the
///      canonical decision JSON (RFC 8785) — inputs read from chain, computed risk factors, model
///      reasoning, confidence, threshold applied, verdict — served publicly at
///      `GET /decision/:hash`. Anyone can fetch it, canonicalise it, hash it, and confirm it
///      matches what was committed here. The commitment is made at decision time, so the
///      reasoning cannot be rewritten afterwards to fit the outcome.
contract PricingRegistry is AccessControl, EIP712 {
    /// @notice May sign pricing decisions. Nothing else — see the contract note above.
    bytes32 public constant PRICER_ROLE = keccak256("PRICER_ROLE");

    /// @notice May consume a quote when minting a policy. Held by xCoverVault.
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice A single pricing decision, quote or refusal.
    struct Decision {
        address reserve; // covered asset the decision is about
        uint256 coverAmount; // cover the quote was priced for, in the reserve's decimals
        uint256 premiumRateRay; // per-block rate; zero when declined
        uint64 validUntilBlock; // a stale quote is a mispriced policy
        bool declined; // true for DECLINE_TO_QUOTE
        bytes32 decisionHash; // hash of the canonical decision JSON
        string engineVersion; // e.g. "pricing-1.2.0/xlayer-usdt"
        uint256 nonce; // makes otherwise identical decisions distinct
    }

    struct QuoteRecord {
        address reserve;
        uint256 coverAmount;
        uint256 premiumRateRay;
        uint64 validUntilBlock;
        bool declined;
        bool consumed;
        bytes32 decisionHash;
        address pricer; // recovered signer, recorded so the decision is attributable
        uint64 recordedAtBlock;
        string engineVersion;
    }

    bytes32 private constant DECISION_TYPEHASH = keccak256(
        "Decision(address reserve,uint256 coverAmount,uint256 premiumRateRay,uint64 validUntilBlock,bool declined,bytes32 decisionHash,string engineVersion,uint256 nonce)"
    );

    /// @notice Every decision ever recorded, keyed by its EIP-712 digest.
    mapping(bytes32 => QuoteRecord) internal _records;

    /// @notice Digests in the order they were recorded, so the full decision history — including
    ///         every refusal — can be walked by anyone without an indexer.
    bytes32[] public quoteHashes;

    /// @notice Count of decisions by outcome. The refusal rate is a published metric, so it is
    ///         cheaper to read it than to reconstruct it from logs.
    uint256 public quotedCount;
    uint256 public declinedCount;

    event DecisionRecorded(
        bytes32 indexed quoteHash,
        address indexed reserve,
        address indexed pricer,
        bool declined,
        uint256 premiumRateRay,
        uint64 validUntilBlock,
        bytes32 decisionHash,
        string engineVersion
    );
    event QuoteConsumed(bytes32 indexed quoteHash, uint256 indexed policyId);

    /// @notice The recovered signer does not hold `PRICER_ROLE`.
    error InvalidPricerSignature(address recovered);
    /// @notice This exact decision has already been recorded.
    error DecisionAlreadyRecorded(bytes32 quoteHash);
    /// @notice No decision has been recorded under this digest.
    error UnknownQuote(bytes32 quoteHash);
    /// @notice The quote's validity window has passed. A stale quote is a mispriced policy.
    error QuoteExpired(bytes32 quoteHash, uint64 validUntilBlock, uint256 currentBlock);
    /// @notice The agent declined to quote this risk. There is no price to mint against.
    error QuoteDeclined(bytes32 quoteHash);
    /// @notice A quote backs exactly one policy.
    error QuoteAlreadyConsumed(bytes32 quoteHash);
    /// @notice The policy being minted does not match what the quote was priced for.
    error QuoteTermsMismatch(bytes32 quoteHash);
    /// @notice A quote must carry a price; a refusal must not.
    error InconsistentDecision();

    constructor(address admin) EIP712("xCover PricingRegistry", "1") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // --- recording ------------------------------------------------------------------------

    /// @notice The EIP-712 digest a pricer signs, and the key every decision is stored under.
    function hashDecision(Decision calldata d) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DECISION_TYPEHASH,
                    d.reserve,
                    d.coverAmount,
                    d.premiumRateRay,
                    d.validUntilBlock,
                    d.declined,
                    d.decisionHash,
                    keccak256(bytes(d.engineVersion)),
                    d.nonce
                )
            )
        );
    }

    /// @notice Record a signed pricing decision — a quote or a refusal.
    /// @dev Permissionless to submit: authority is the signature, not the sender. A refusal is
    ///      recorded on exactly the same path as a quote, which is what makes the refusal rate
    ///      auditable rather than self-reported.
    function recordDecision(Decision calldata d, bytes calldata signature)
        external
        returns (bytes32 quoteHash)
    {
        // A declined decision carries no price, and a quote without one would mint free cover.
        if (d.declined != (d.premiumRateRay == 0)) revert InconsistentDecision();

        quoteHash = hashDecision(d);
        if (_records[quoteHash].pricer != address(0)) revert DecisionAlreadyRecorded(quoteHash);

        address signer = ECDSA.recover(quoteHash, signature);
        if (!hasRole(PRICER_ROLE, signer)) revert InvalidPricerSignature(signer);

        _records[quoteHash] = QuoteRecord({
            reserve: d.reserve,
            coverAmount: d.coverAmount,
            premiumRateRay: d.premiumRateRay,
            validUntilBlock: d.validUntilBlock,
            declined: d.declined,
            consumed: false,
            decisionHash: d.decisionHash,
            pricer: signer,
            recordedAtBlock: uint64(block.number),
            engineVersion: d.engineVersion
        });
        quoteHashes.push(quoteHash);

        if (d.declined) declinedCount++;
        else quotedCount++;

        emit DecisionRecorded(
            quoteHash,
            d.reserve,
            signer,
            d.declined,
            d.premiumRateRay,
            d.validUntilBlock,
            d.decisionHash,
            d.engineVersion
        );
    }

    // --- consumption ----------------------------------------------------------------------

    /// @notice Consume a quote to back a policy mint, checking it is live and matches the terms.
    /// @dev Every reason a quote cannot back this policy is a distinct error, because the user
    ///      is owed the actual reason their deposit did not receive cover — particularly when the
    ///      answer is that the agent declined to price it.
    function consumeQuote(bytes32 quoteHash, address reserve, uint256 coverAmount, uint256 policyId)
        external
        onlyRole(VAULT_ROLE)
        returns (uint256 premiumRateRay)
    {
        QuoteRecord storage r = _records[quoteHash];
        if (r.pricer == address(0)) revert UnknownQuote(quoteHash);
        if (r.declined) revert QuoteDeclined(quoteHash);
        if (r.consumed) revert QuoteAlreadyConsumed(quoteHash);
        if (block.number > r.validUntilBlock) {
            revert QuoteExpired(quoteHash, r.validUntilBlock, block.number);
        }
        if (r.reserve != reserve || r.coverAmount != coverAmount) {
            revert QuoteTermsMismatch(quoteHash);
        }

        r.consumed = true;
        emit QuoteConsumed(quoteHash, policyId);

        return r.premiumRateRay;
    }

    // --- views ----------------------------------------------------------------------------

    function records(bytes32 quoteHash) external view returns (QuoteRecord memory) {
        QuoteRecord memory r = _records[quoteHash];
        if (r.pricer == address(0)) revert UnknownQuote(quoteHash);
        return r;
    }

    /// @notice True only if this quote could back a policy mint at the current block.
    function isQuoteLive(bytes32 quoteHash) external view returns (bool) {
        QuoteRecord storage r = _records[quoteHash];
        return r.pricer != address(0) && !r.declined && !r.consumed
            && block.number <= r.validUntilBlock;
    }

    /// @notice Total decisions recorded, quotes and refusals together.
    function decisionCount() external view returns (uint256) {
        return quoteHashes.length;
    }
}
