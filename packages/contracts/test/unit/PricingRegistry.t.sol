// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PricingRegistry} from "../../src/PricingRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Quotes, refusals, freshness, and the limits of what the pricing key can do.
/// @dev The refusal path gets the same coverage as the happy path here, deliberately: it is a
///      first-class outcome, not an error branch (SPEC §1.2.3).
contract PricingRegistryTest is Test {
    PricingRegistry internal registry;

    uint256 internal pricerKey = 0xA11CE;
    address internal pricer;
    address internal vault = makeAddr("vault");
    address internal stranger = makeAddr("stranger");
    address internal reserve = makeAddr("usdt");

    string internal constant ENGINE = "pricing-1.0.0/xlayer-usdt";

    function setUp() public {
        pricer = vm.addr(pricerKey);
        registry = new PricingRegistry(address(this));
        registry.grantRole(registry.PRICER_ROLE(), pricer);
        registry.grantRole(registry.VAULT_ROLE(), vault);
        vm.roll(1_000);
    }

    function _decision(bool declined, uint256 rate, uint64 validFor, uint256 nonce)
        internal
        view
        returns (PricingRegistry.Decision memory)
    {
        return PricingRegistry.Decision({
            reserve: reserve,
            coverAmount: 10_000e6,
            premiumRateRay: rate,
            validUntilBlock: uint64(block.number) + validFor,
            declined: declined,
            decisionHash: keccak256(abi.encode("canonical decision json", nonce)),
            engineVersion: ENGINE,
            nonce: nonce
        });
    }

    function _sign(PricingRegistry.Decision memory d, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        bytes32 digest = this.hash(arr);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev External so the calldata-typed `hashDecision` can be reached from memory structs.
    function hash(PricingRegistry.Decision[] calldata d) external view returns (bytes32) {
        return registry.hashDecision(d[0]);
    }

    function _record(PricingRegistry.Decision memory d) internal returns (bytes32) {
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        return this.record(arr, _sign(d, pricerKey));
    }

    function record(PricingRegistry.Decision[] calldata d, bytes calldata sig)
        external
        returns (bytes32)
    {
        return registry.recordDecision(d[0], sig);
    }

    // --- quotes ---------------------------------------------------------------------------

    function test_RecordsASignedQuote() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        PricingRegistry.QuoteRecord memory r = registry.records(h);
        assertEq(r.pricer, pricer, "decision is not attributable to the signer");
        assertEq(r.premiumRateRay, 1e21);
        assertFalse(r.declined);
        assertFalse(r.consumed);
        assertTrue(registry.isQuoteLive(h));
        assertEq(registry.quotedCount(), 1);
        assertEq(registry.declinedCount(), 0);
        assertEq(registry.decisionCount(), 1);
    }

    /// @dev Authority is the signature, not the sender: the pricing key never needs gas.
    function test_AnyoneMaySubmitAPricerSignedDecision() public {
        PricingRegistry.Decision memory d = _decision(false, 1e21, 50, 1);
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;

        vm.prank(stranger);
        bytes32 h = this.record(arr, _sign(d, pricerKey));

        assertEq(registry.records(h).pricer, pricer);
    }

    function test_RejectsASignatureFromANonPricer() public {
        uint256 rogueKey = 0xBAD;
        PricingRegistry.Decision memory d = _decision(false, 1e21, 50, 1);
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        // Signed before arming the cheatcode: `_sign` makes an external call of its own.
        bytes memory sig = _sign(d, rogueKey);

        vm.expectRevert(
            abi.encodeWithSelector(
                PricingRegistry.InvalidPricerSignature.selector, vm.addr(rogueKey)
            )
        );
        this.record(arr, sig);
    }

    /// @dev A decision that was signed for different terms must not be replayable against these.
    function test_RejectsASignatureOverDifferentTerms() public {
        PricingRegistry.Decision memory signed = _decision(false, 1e21, 50, 1);
        bytes memory sig = _sign(signed, pricerKey);

        PricingRegistry.Decision memory tampered = signed;
        tampered.premiumRateRay = 1; // a cheaper price than the agent actually signed

        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = tampered;

        // Recovery yields some other address, which does not hold PRICER_ROLE.
        vm.expectRevert();
        this.record(arr, sig);
    }

    function test_RejectsADuplicateDecision() public {
        PricingRegistry.Decision memory d = _decision(false, 1e21, 50, 1);
        bytes32 h = _record(d);

        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        bytes memory sig = _sign(d, pricerKey);

        vm.expectRevert(
            abi.encodeWithSelector(PricingRegistry.DecisionAlreadyRecorded.selector, h)
        );
        this.record(arr, sig);
    }

    // --- refusals -------------------------------------------------------------------------

    /// @dev A refusal is a successful outcome with a permanent record, not an error.
    function test_RecordsARefusal() public {
        bytes32 h = _record(_decision(true, 0, 50, 1));

        PricingRegistry.QuoteRecord memory r = registry.records(h);
        assertTrue(r.declined, "refusal was not recorded as declined");
        assertEq(r.premiumRateRay, 0);
        assertEq(r.pricer, pricer);
        assertEq(registry.declinedCount(), 1);
        assertEq(registry.quotedCount(), 0);
        assertEq(registry.decisionCount(), 1, "refusal is missing from the decision history");
    }

    function test_ARefusalIsNotLiveAndCannotBackAPolicy() public {
        bytes32 h = _record(_decision(true, 0, 50, 1));

        assertFalse(registry.isQuoteLive(h));

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteDeclined.selector, h));
        registry.consumeQuote(h, reserve, 10_000e6, 1);
    }

    /// @dev A priced refusal or a free quote are both incoherent, and both would be dangerous:
    ///      the first hides a price behind a refusal, the second mints cover for nothing.
    function test_RejectsAPricedRefusal() public {
        PricingRegistry.Decision memory d = _decision(true, 1e21, 50, 1);
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;

        bytes memory sig = _sign(d, pricerKey);

        vm.expectRevert(PricingRegistry.InconsistentDecision.selector);
        this.record(arr, sig);
    }

    function test_RejectsAQuoteWithNoPrice() public {
        PricingRegistry.Decision memory d = _decision(false, 0, 50, 1);
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;

        bytes memory sig = _sign(d, pricerKey);

        vm.expectRevert(PricingRegistry.InconsistentDecision.selector);
        this.record(arr, sig);
    }

    /// @dev Both outcomes are recorded identically, which is what makes the published refusal
    ///      rate auditable rather than self-reported.
    function test_RefusalsAndQuotesShareTheSameHistory() public {
        _record(_decision(false, 1e21, 50, 1));
        _record(_decision(true, 0, 50, 2));
        _record(_decision(false, 2e21, 50, 3));

        assertEq(registry.decisionCount(), 3);
        assertEq(registry.quotedCount(), 2);
        assertEq(registry.declinedCount(), 1);
        assertTrue(registry.records(registry.quoteHashes(1)).declined);
    }

    // --- freshness and consumption --------------------------------------------------------

    function test_ConsumingAQuoteReturnsItsRateAndBurnsIt() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.prank(vault);
        uint256 rate = registry.consumeQuote(h, reserve, 10_000e6, 7);

        assertEq(rate, 1e21);
        assertTrue(registry.records(h).consumed);
        assertFalse(registry.isQuoteLive(h));
    }

    function test_AQuoteBacksExactlyOnePolicy() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.prank(vault);
        registry.consumeQuote(h, reserve, 10_000e6, 7);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteAlreadyConsumed.selector, h));
        registry.consumeQuote(h, reserve, 10_000e6, 8);
    }

    /// @dev A stale quote is a mispriced policy.
    function test_AnExpiredQuoteCannotBeConsumed() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));
        uint64 validUntil = registry.records(h).validUntilBlock;

        vm.roll(uint256(validUntil) + 1);
        assertFalse(registry.isQuoteLive(h));

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                PricingRegistry.QuoteExpired.selector, h, validUntil, block.number
            )
        );
        registry.consumeQuote(h, reserve, 10_000e6, 7);
    }

    function test_AQuoteIsStillLiveOnItsFinalBlock() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.roll(registry.records(h).validUntilBlock);
        assertTrue(registry.isQuoteLive(h), "quote expired a block early");

        vm.prank(vault);
        registry.consumeQuote(h, reserve, 10_000e6, 7);
    }

    /// @dev A quote priced for one risk must not be spent on another.
    function test_RejectsAQuotePricedForDifferentTerms() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteTermsMismatch.selector, h));
        registry.consumeQuote(h, reserve, 50_000e6, 7);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.QuoteTermsMismatch.selector, h));
        registry.consumeQuote(h, makeAddr("otherReserve"), 10_000e6, 7);
    }

    function test_UnknownQuoteReverts() public {
        bytes32 h = keccak256("never recorded");

        vm.expectRevert(abi.encodeWithSelector(PricingRegistry.UnknownQuote.selector, h));
        registry.records(h);
        assertFalse(registry.isQuoteLive(h));
    }

    // --- the limits of the pricing key ----------------------------------------------------

    /// @dev The pricer signs decisions. It cannot spend one — only the vault consumes quotes, and
    ///      consumption is what turns a price into a policy.
    function test_PricerCannotConsumeItsOwnQuote() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                pricer,
                registry.VAULT_ROLE()
            )
        );
        vm.prank(pricer);
        registry.consumeQuote(h, reserve, 10_000e6, 7);
    }

    function test_OnlyVaultCanConsume() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                registry.VAULT_ROLE()
            )
        );
        vm.prank(stranger);
        registry.consumeQuote(h, reserve, 10_000e6, 7);
    }

    /// @dev Revoking the key stops future decisions and leaves past ones standing — the history
    ///      is a record of what was decided, not a claim that the signer is still trusted.
    function test_RevokedPricerCannotRecordButHistoryRemains() public {
        bytes32 h = _record(_decision(false, 1e21, 50, 1));
        registry.revokeRole(registry.PRICER_ROLE(), pricer);

        PricingRegistry.Decision memory d = _decision(false, 1e21, 50, 2);
        PricingRegistry.Decision[] memory arr = new PricingRegistry.Decision[](1);
        arr[0] = d;
        bytes memory sig = _sign(d, pricerKey);

        vm.expectRevert(
            abi.encodeWithSelector(PricingRegistry.InvalidPricerSignature.selector, pricer)
        );
        this.record(arr, sig);

        assertEq(registry.records(h).pricer, pricer);
        assertEq(registry.decisionCount(), 1);
    }
}
