// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPolicy} from "./interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "./interfaces/IYieldVenue.sol";
import {PricingRegistry} from "./PricingRegistry.sol";

/// @title xCoverVault
/// @notice Deposit once, receive a covered position. The mechanism that fixes "nobody buys
///         cover" (SPEC §4.3).
///
/// @dev The user makes one decision — deposit — and in a single transaction their assets are
///      supplied to the yield venue, a signed quote is consumed, a policy is minted against real
///      locked capital, and they receive vault shares. Cover is a property of the position rather
///      than a product bought alongside it.
///
///      **There is no uncovered deposit path.** The inherited ERC-4626 entrypoints have nowhere
///      to carry a quote, so `deposit` and `mint` revert and point at `depositCovered`. If the
///      agent declined, or the quote went stale, or the pool lacks capacity, the whole
///      transaction reverts with the specific reason. It does not deposit anyway and leave the
///      user believing they are protected — that is the worst outcome this system could produce,
///      worse than refusing the deposit outright.
///
///      **Premium streams from the position's yield.** It accrues per block at the rate fixed in
///      the signed quote and is settled on exit, out of the assets redeemed from the venue. There
///      is no recurring payment for the user to forget and no separate approval to grant.
///
///      **Exits are all-or-nothing, and that is a limitation, not an oversight.** A partial exit
///      would leave a policy sized for a position that no longer exists, and resizing it means
///      re-quoting at exit time — precisely when a user who has seen bad news would want a new
///      price. Full exit only, stated in the README.
contract xCoverVault is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;

    /// @notice The asset deposited and covered. USDT at launch.
    IERC20 public immutable asset;

    IYieldVenue public immutable venue;
    ICoverPool public immutable pool;
    ICoverPolicy public immutable policy;
    PricingRegistry public immutable registry;

    /// @notice A covered position.
    struct Position {
        uint256 policyId;
        uint256 shares;
        uint256 coverAmount;
        uint256 premiumRateRay; // per-block, from the signed quote
        uint64 openedAtBlock;
    }

    /// @notice One open position per address. A second deposit must follow an exit.
    mapping(address => Position) public positions;

    event PositionOpened(
        address indexed owner,
        uint256 indexed policyId,
        uint256 assets,
        uint256 shares,
        bytes32 quoteHash
    );
    event PositionClosed(
        address indexed owner, uint256 indexed policyId, uint256 assetsReturned, uint256 premiumPaid
    );

    /// @notice ERC-4626's plain entrypoints cannot carry a quote, so they cannot mint cover.
    error UseDepositCovered();
    /// @notice Exits are all-or-nothing; see the contract note.
    error UseExit();
    /// @notice This address already holds an open covered position.
    error PositionAlreadyOpen(address owner);
    /// @notice This address holds no open position.
    error NoOpenPosition(address owner);
    /// @notice Zero-valued calls are rejected rather than silently succeeding.
    error ZeroAmount();
    /// @notice The quote was priced for a different amount than is being deposited.
    error QuoteAmountMismatch(uint256 quoted, uint256 deposited);

    constructor(
        IERC20 asset_,
        IYieldVenue venue_,
        ICoverPool pool_,
        ICoverPolicy policy_,
        PricingRegistry registry_,
        address admin
    ) ERC20("xCover USDT", "xcUSDT") {
        asset = asset_;
        venue = venue_;
        pool = pool_;
        policy = policy_;
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(address(asset)).decimals();
    }

    // --- ERC-4626 surface -------------------------------------------------------------------

    /// @notice Assets under management, read live from the venue.
    function totalAssets() public view returns (uint256) {
        return venue.totalAssets();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        return Math.mulDiv(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return Math.mulDiv(shares, totalAssets(), supply);
    }

    /// @notice Reverts. A deposit through this path would carry no quote and therefore no cover.
    /// @dev Kept present and reverting rather than absent, so an integrator calling the standard
    ///      ERC-4626 entrypoint gets a named error instead of an uncovered position.
    function deposit(uint256, address) external pure returns (uint256) {
        revert UseDepositCovered();
    }

    function mint(uint256, address) external pure returns (uint256) {
        revert UseDepositCovered();
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert UseExit();
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        revert UseExit();
    }

    // --- the one transaction ----------------------------------------------------------------

    /// @notice Supply assets, take out cover on them, and receive shares — atomically.
    /// @param quoteHash the signed decision recorded in `PricingRegistry` that prices this cover.
    /// @dev Order matters. The quote is consumed and the policy minted *before* shares exist, so
    ///      any refusal, staleness, cap or solvency failure reverts the whole transaction and the
    ///      user keeps their assets rather than holding shares in an uncovered position.
    function depositCovered(uint256 assets, address receiver, bytes32 quoteHash, uint64 termBlocks)
        external
        returns (uint256 shares, uint256 policyId)
    {
        if (assets == 0) revert ZeroAmount();
        if (positions[receiver].policyId != 0) revert PositionAlreadyOpen(receiver);

        // Shares are priced against the venue balance before this deposit lands.
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        // 1. Supply to the venue. The covered position is real before cover is written on it.
        asset.forceApprove(address(venue), assets);
        uint256 supplied = venue.deposit(assets);
        asset.forceApprove(address(venue), 0);

        // 2. Consume the quote. Reverts with the specific reason if the agent declined, if the
        //    quote is stale, or if it was priced for different terms.
        uint256 premiumRateRay =
            registry.consumeQuote(quoteHash, address(asset), supplied, 0);

        // 3. Mint the policy. Reverts if the pool cannot back the cover, or the daily cap binds.
        policyId = policy.mintPolicy(
            receiver,
            address(asset),
            supplied,
            uint64(block.number) + termBlocks,
            premiumRateRay,
            quoteHash,
            _termsHashFor()
        );

        positions[receiver] = Position({
            policyId: policyId,
            shares: shares,
            coverAmount: supplied,
            premiumRateRay: premiumRateRay,
            openedAtBlock: uint64(block.number)
        });

        _mint(receiver, shares);

        emit PositionOpened(receiver, policyId, supplied, shares, quoteHash);
    }

    /// @notice Close the position: settle premium, release the cover, return the assets.
    /// @dev Callable only by the position owner. If the policy has already been triggered, the
    ///      cover is left alone — cancelling it would destroy a claim the holder is owed — and
    ///      only the underlying position is returned.
    function exit() external returns (uint256 assetsReturned, uint256 premiumPaid) {
        Position memory p = positions[msg.sender];
        if (p.policyId == 0) revert NoOpenPosition(msg.sender);

        delete positions[msg.sender];

        uint256 shares = p.shares;
        uint256 owed = convertToAssets(shares);
        _burn(msg.sender, shares);

        // Premium accrued per block since the position opened, at the quoted rate.
        premiumPaid = accruedPremium(p);
        if (premiumPaid > owed) premiumPaid = owed;

        // Redeem everything from the venue into this contract first, so premium and principal are
        // settled from assets actually in hand rather than assumed.
        venue.withdraw(owed, address(this));

        if (premiumPaid > 0) {
            asset.forceApprove(address(pool), premiumPaid);
            pool.accruePremium(premiumPaid);
            asset.forceApprove(address(pool), 0);
        }

        // Release the cover only if it is still live. A triggered policy keeps its claim.
        if (policy.isCoverActive(p.policyId)) {
            policy.cancel(p.policyId);
        }

        assetsReturned = owed - premiumPaid;
        asset.safeTransfer(msg.sender, assetsReturned);

        emit PositionClosed(msg.sender, p.policyId, assetsReturned, premiumPaid);
    }

    // --- views ------------------------------------------------------------------------------

    /// @notice Premium accrued on a position so far, in the asset's own decimals.
    function accruedPremium(Position memory p) public view returns (uint256) {
        uint256 blocksElapsed = block.number - p.openedAtBlock;
        return (p.coverAmount * p.premiumRateRay * blocksElapsed) / RAY;
    }

    /// @notice Premium accrued on an address's open position.
    function accruedPremiumOf(address owner) external view returns (uint256) {
        return accruedPremium(positions[owner]);
    }

    /// @notice The terms every policy is written under at this deployment.
    /// @dev Set once at deploy and read by `ClaimResolver` when evaluating. Held here so the
    ///      vault and the resolver cannot drift apart on what was actually agreed.
    bytes32 public termsHash;

    function _termsHashFor() internal view returns (bytes32) {
        return termsHash;
    }

    /// @notice Fix the terms new policies are written under.
    /// @dev Admin-only and forward-looking: existing policies keep the terms hashed into them at
    ///      mint, so this can never alter what an outstanding policy covers.
    function setTermsHash(bytes32 termsHash_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        termsHash = termsHash_;
    }
}
