// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {PricingRegistry} from "../../src/PricingRegistry.sol";
import {xCoverVault} from "../../src/xCoverVault.sol";
import {TestnetVenue} from "../../src/venues/TestnetVenue.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "../../src/interfaces/IYieldVenue.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The single-transaction covered deposit, and every way it is allowed to fail.
/// @dev The refusal cases carry the weight here. A vault that opens a covered position correctly
///      but also opens an *uncovered* one when the agent declines has failed at the only thing
///      that distinguishes this product from a plain yield vault.
contract xCoverVaultTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    PricingRegistry internal registry;
    TestnetVenue internal venue;
    xCoverVault internal vault;
    TestUSDT internal asset;

    uint256 internal pricerKey = 0xA11CE;
    address internal pricer;
    address internal provider = makeAddr("provider");
    address internal user = makeAddr("user");
    address internal resolver = makeAddr("resolver");

    uint64 internal constant WAITING = 100;
    uint64 internal constant TERM = 10_000;
    uint256 internal constant DEPOSIT = 50_000e6;
    // 1e18 / 1e27 = 1e-9 of cover per block. Over 10,000 blocks that is 0.5 USDT on 50,000.
    uint256 internal constant RATE_RAY = 1e18;

    bytes32 internal termsHash = keccak256("terms-v1");
    uint256 internal nonce;

    function setUp() public {
        pricer = vm.addr(pricerKey);

        asset = new TestUSDT();
        pool = new CoverPool(asset, address(this));
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, 1_000_000e6, address(this));
        registry = new PricingRegistry(address(this));
        venue = new TestnetVenue(IERC20(address(asset)), address(this));
        vault = new xCoverVault(
            IERC20(address(asset)),
            IYieldVenue(address(venue)),
            ICoverPool(address(pool)),
            ICoverPolicy(address(policy)),
            registry,
            address(this)
        );

        pool.grantRole(pool.VAULT_ROLE(), address(policy));
        pool.grantRole(pool.CLAIM_ROLE(), resolver);
        policy.grantRole(policy.VAULT_ROLE(), address(vault));
        policy.grantRole(policy.CLAIM_ROLE(), resolver);
        venue.grantRole(venue.VAULT_ROLE(), address(vault));
        registry.grantRole(registry.PRICER_ROLE(), pricer);
        registry.grantRole(registry.VAULT_ROLE(), address(vault));
        vault.setTermsHash(termsHash);

        asset.mint(provider, 1_000_000e6);
        vm.startPrank(provider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(1_000_000e6);
        vm.stopPrank();

        asset.mint(user, 200_000e6);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);

        vm.roll(1_000);
    }

    // --- quote helpers ----------------------------------------------------------------------

    function _quote(bool declined, uint256 rate, uint256 coverAmount, uint64 validFor)
        internal
        returns (bytes32)
    {
        nonce++;
        PricingRegistry.Decision memory d = PricingRegistry.Decision({
            reserve: address(asset),
            coverAmount: coverAmount,
            premiumRateRay: rate,
            validUntilBlock: uint64(block.number) + validFor,
            declined: declined,
            decisionHash: keccak256(abi.encode("decision", nonce)),
            engineVersion: "pricing-1.0.0/xlayer-usdt",
            nonce: nonce
        });
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        bytes32 digest = this.hashDecision(arr);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pricerKey, digest);
        return this.recordDecision(arr, abi.encodePacked(r, s, v));
    }

    function hashDecision(PricingRegistry.Decision[] calldata d) external view returns (bytes32) {
        return registry.hashDecision(d[0]);
    }

    function recordDecision(PricingRegistry.Decision[] calldata d, bytes calldata sig)
        external
        returns (bytes32)
    {
        return registry.recordDecision(d[0], sig);
    }

    function _goodQuote() internal returns (bytes32) {
        return _quote(false, RATE_RAY, DEPOSIT, 50);
    }

    // --- the covered deposit ------------------------------------------------------------------

    function test_OneTransactionYieldsACoveredPosition() public {
        bytes32 q = _goodQuote();

        vm.prank(user);
        (uint256 shares, uint256 policyId) = vault.depositCovered(DEPOSIT, user, q, TERM);

        // Assets are in the venue, not idle in the vault.
        assertEq(venue.totalAssets(), DEPOSIT, "assets were not supplied to the venue");
        assertEq(asset.balanceOf(address(vault)), 0);

        // The user holds shares and the policy.
        assertEq(vault.balanceOf(user), shares);
        assertEq(policy.ownerOf(policyId), user, "policy was not minted to the depositor");

        // The cover is backed by real locked capital.
        assertEq(pool.coverOf(policyId), DEPOSIT);
        assertEq(pool.freeCapital(), 1_000_000e6 - DEPOSIT);

        // And it is one transaction: the position records both halves together.
        (uint256 storedId,, uint256 coverAmount,,) = vault.positions(user);
        assertEq(storedId, policyId);
        assertEq(coverAmount, DEPOSIT);
    }

    function test_PolicyCarriesTheQuoteAndTermsItWasWrittenUnder() public {
        bytes32 q = _goodQuote();
        vm.prank(user);
        (, uint256 policyId) = vault.depositCovered(DEPOSIT, user, q, TERM);

        ICoverPolicy.Policy memory p = policy.policies(policyId);
        assertEq(p.quoteHash, q, "policy does not link to its pricing decision");
        assertEq(p.termsHash, termsHash, "policy does not carry the terms");
        assertEq(p.premiumRateRay, RATE_RAY, "policy rate is not the quoted rate");
    }

    function test_QuoteIsConsumedAndCannotBackASecondDeposit() public {
        bytes32 q = _goodQuote();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q, TERM);

        address second = makeAddr("second");
        asset.mint(second, DEPOSIT);
        vm.startPrank(second);
        asset.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteAlreadyConsumed.selector, q));
        vault.depositCovered(DEPOSIT, second, q, TERM);
        vm.stopPrank();
    }

    // --- refusal and failure paths ------------------------------------------------------------

    /// @dev The single most important test in this file. When the agent declines, the user keeps
    ///      their money and is told why. They do not end up holding shares in an uncovered
    ///      position while believing they are protected.
    function test_ADeclinedQuoteRefusesTheDepositAndReturnsNothing() public {
        bytes32 refusal = _quote(true, 0, DEPOSIT, 50);
        uint256 balanceBefore = asset.balanceOf(user);

        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteDeclined.selector, refusal));
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, refusal, TERM);

        assertEq(asset.balanceOf(user), balanceBefore, "user lost assets to a refused deposit");
        assertEq(vault.balanceOf(user), 0, "shares were issued without cover");
        assertEq(venue.totalAssets(), 0, "assets were supplied despite the refusal");
        assertEq(pool.outstandingCover(), 0);
    }

    function test_AStaleQuoteRefusesTheDeposit() public {
        bytes32 q = _goodQuote();
        vm.roll(block.number + 51);

        vm.expectRevert();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q, TERM);

        assertEq(vault.balanceOf(user), 0);
        assertEq(venue.totalAssets(), 0);
    }

    /// @dev Capacity is finite because cover is fully collateralized. Running out is a refusal,
    ///      not a silent uncovered deposit.
    function test_ADepositBeyondPoolCapacityIsRefused() public {
        // Drain free capital down below the deposit size. The share balance is read before the
        // prank: an external call in the argument list would consume it.
        uint256 providerShares = pool.sharesOf(provider);
        vm.prank(provider);
        pool.withdrawCapital(providerShares);

        bytes32 q = _goodQuote();
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.InsufficientFreeCapital.selector, DEPOSIT, 0)
        );
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q, TERM);

        assertEq(vault.balanceOf(user), 0, "shares issued with no capital behind the cover");
        assertEq(venue.totalAssets(), 0);
    }

    function test_AQuotePricedForADifferentAmountIsRefused() public {
        bytes32 q = _quote(false, RATE_RAY, DEPOSIT, 50);

        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteTermsMismatch.selector, q));
        vm.prank(user);
        vault.depositCovered(DEPOSIT / 2, user, q, TERM);
    }

    /// @dev The standard ERC-4626 entrypoints have nowhere to carry a quote, so they cannot mint
    ///      cover. They revert by name rather than quietly producing an uncovered position.
    function test_PlainErc4626EntrypointsRefuse() public {
        vm.startPrank(user);

        vm.expectRevert(xCoverVault.UseDepositCovered.selector);
        vault.deposit(DEPOSIT, user);

        vm.expectRevert(xCoverVault.UseDepositCovered.selector);
        vault.mint(DEPOSIT, user);

        vm.expectRevert(xCoverVault.UseExit.selector);
        vault.withdraw(DEPOSIT, user, user);

        vm.expectRevert(xCoverVault.UseExit.selector);
        vault.redeem(DEPOSIT, user, user);

        vm.stopPrank();
    }

    function test_OnePositionPerAddress() public {
        bytes32 q1 = _goodQuote();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q1, TERM);

        bytes32 q2 = _goodQuote();
        vm.expectRevert(abi.encodeWithSelector(xCoverVault.PositionAlreadyOpen.selector, user));
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q2, TERM);
    }

    function test_VaultSharesAreNonTransferable() public {
        bytes32 q = _goodQuote();
        vm.prank(user);
        (uint256 shares,) = vault.depositCovered(DEPOSIT, user, q, TERM);

        address buyer = makeAddr("buyer");
        vm.prank(user);
        vm.expectRevert(xCoverVault.PositionTransfersDisabled.selector);
        vault.transfer(buyer, shares);

        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.balanceOf(buyer), 0);
    }

    // --- exit -----------------------------------------------------------------------------

    function test_ExitReturnsAssetsAndPaysPremiumToThePool() public {
        bytes32 q = _goodQuote();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q, TERM);

        vm.roll(block.number + 1_000);

        uint256 expectedPremium = vault.accruedPremiumOf(user);
        assertGt(expectedPremium, 0, "no premium accrued over 1,000 blocks");

        uint256 capitalBefore = pool.capital();
        vm.prank(user);
        (uint256 returned, uint256 premiumPaid) = vault.exit();

        assertEq(premiumPaid, expectedPremium);
        assertEq(returned, DEPOSIT - expectedPremium, "user was not returned the balance");
        assertEq(asset.balanceOf(user), 200_000e6 - DEPOSIT + returned);

        // The premium reached the capital providers, raising their capital.
        assertEq(pool.capital(), capitalBefore + premiumPaid, "premium did not reach the pool");

        // The cover is released and the capital unlocked.
        assertEq(pool.outstandingCover(), 0);
        assertEq(vault.balanceOf(user), 0);
        assertEq(venue.totalAssets(), 0);
    }

    /// @dev Premium is owed for cover that was genuinely provided, whether or not the venue
    ///      produced yield to pay it from. On testnet there is no yield source, so it comes out
    ///      of principal — a real consequence, stated rather than hidden.
    function test_PremiumComesFromPrincipalWhenTheVenueHasNoYield() public {
        assertFalse(venue.hasYieldSource());

        bytes32 q = _goodQuote();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q, TERM);
        vm.roll(block.number + 1_000);

        vm.prank(user);
        (uint256 returned, uint256 premiumPaid) = vault.exit();

        assertLt(returned, DEPOSIT, "premium was not actually charged");
        assertEq(returned + premiumPaid, DEPOSIT);
    }

    function test_ExitAllowsANewPositionAfterwards() public {
        bytes32 q1 = _goodQuote();
        vm.prank(user);
        vault.depositCovered(DEPOSIT, user, q1, TERM);
        vm.roll(block.number + 10);
        vm.prank(user);
        vault.exit();

        // Priced for the amount actually being deposited — a quote is bound to its terms.
        bytes32 q2 = _quote(false, RATE_RAY, DEPOSIT / 2, 50);
        vm.prank(user);
        (, uint256 policyId) = vault.depositCovered(DEPOSIT / 2, user, q2, TERM);
        assertEq(policy.ownerOf(policyId), user);
    }

    function test_ExitWithoutAPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(xCoverVault.NoOpenPosition.selector, user));
        vm.prank(user);
        vault.exit();
    }

    /// @dev A triggered policy keeps its claim. Exiting the underlying position must not cancel
    ///      cover the holder is already owed a payout on.
    function test_ExitDoesNotCancelATriggeredPolicy() public {
        bytes32 q = _goodQuote();
        vm.prank(user);
        (, uint256 policyId) = vault.depositCovered(DEPOSIT, user, q, TERM);

        vm.roll(policy.activeFromBlock(policyId));
        vm.prank(resolver);
        policy.markClaimable(policyId);

        vm.prank(user);
        vault.exit();

        // The claim survives the exit, and the capital behind it stays locked.
        assertEq(
            uint8(policy.policies(policyId).state), uint8(ICoverPolicy.PolicyState.Claimable)
        );
        assertEq(pool.coverOf(policyId), DEPOSIT, "cover was released out from under a claim");

        // And it still pays.
        vm.prank(resolver);
        pool.payClaim(policyId, user, DEPOSIT);
        assertGt(asset.balanceOf(user), 200_000e6 - 1e6);
    }

    function test_ZeroDepositReverts() public {
        bytes32 q = _goodQuote();
        vm.expectRevert(xCoverVault.ZeroAmount.selector);
        vm.prank(user);
        vault.depositCovered(0, user, q, TERM);
    }
}
