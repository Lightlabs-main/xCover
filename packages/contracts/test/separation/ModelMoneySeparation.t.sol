// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPolicy} from "../../src/CoverPolicy.sol";
import {PricingRegistry} from "../../src/PricingRegistry.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../../src/interfaces/ICoverPolicy.sol";
import {TestUSDT} from "../utils/TestUSDT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {XLayerAddresses} from "../../src/XLayerAddresses.sol";

/// @title ModelMoneySeparation
/// @notice The structural separation between the model and the money (SPEC §4.7).
///
/// @dev These are the most persuasive tests in the suite, because they prove rule 1.2.2 — the
///      agent prices risk and never moves funds — holds at the contract level rather than by
///      convention in the backend. Each asserts an *absence*: a thing the privileged key cannot
///      do, no matter who holds it.
///
///      The pricing key is deliberately given every role it legitimately needs before each test.
///      A separation test that passes because the key was never granted anything proves nothing.
contract ModelMoneySeparationTest is Test {
    CoverPool internal pool;
    CoverPolicy internal policy;
    PricingRegistry internal registry;
    TestUSDT internal asset;

    uint256 internal pricerKey = 0xA11CE;
    address internal pricer;
    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("vault");
    address internal resolver = makeAddr("resolver");
    address internal provider = makeAddr("provider");
    address internal holder = makeAddr("holder");

    uint64 internal constant WAITING = 100;
    uint256 internal constant DAILY_CAP = 1_000_000e6;

    function setUp() public {
        pricer = vm.addr(pricerKey);

        asset = new TestUSDT();
        pool = new CoverPool(asset, admin);
        policy = new CoverPolicy(ICoverPool(address(pool)), WAITING, DAILY_CAP, admin);
        registry = new PricingRegistry(admin);

        vm.startPrank(admin);
        pool.grantRole(pool.VAULT_ROLE(), address(policy));
        pool.grantRole(pool.CLAIM_ROLE(), resolver);
        policy.grantRole(policy.VAULT_ROLE(), vault);
        policy.grantRole(policy.CLAIM_ROLE(), resolver);

        // The pricer is given the full extent of its legitimate authority: it may sign pricing
        // decisions. Everything below asserts what that authority does not reach.
        registry.grantRole(registry.PRICER_ROLE(), pricer);
        registry.grantRole(registry.VAULT_ROLE(), vault);
        vm.stopPrank();

        asset.mint(provider, 1_000_000e6);
        vm.startPrank(provider);
        asset.approve(address(pool), type(uint256).max);
        pool.depositCapital(1_000_000e6);
        vm.stopPrank();

        vm.roll(1_000);
    }

    function _mint(uint256 coverAmount) internal returns (uint256) {
        vm.prank(vault);
        return policy.mintPolicy(
            holder,
            address(asset),
            coverAmount,
            uint64(block.number) + 10_000,
            1e21,
            keccak256("quote"),
            keccak256("terms")
        );
    }

    function _expectDenied(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, account, role
            )
        );
    }

    // --- the pricer cannot touch money ----------------------------------------------------

    /// @notice The pricing key cannot move pool capital by any route the pool exposes.
    function test_PricerCannotMovePoolFunds() public {
        uint256 id = _mint(10_000e6);
        uint256 capitalBefore = pool.capital();
        uint256 balanceBefore = asset.balanceOf(address(pool));

        // Cannot settle a claim to itself.
        _expectDenied(pricer, pool.CLAIM_ROLE());
        vm.prank(pricer);
        pool.payClaim(id, pricer, 10_000e6);

        // Cannot reserve cover, which is what locks capital against an obligation.
        _expectDenied(pricer, pool.VAULT_ROLE());
        vm.prank(pricer);
        pool.reserveCover(999, 10_000e6);

        // Cannot release someone else's cover to free up capital.
        _expectDenied(pricer, pool.VAULT_ROLE());
        vm.prank(pricer);
        pool.releaseCover(id);

        // Cannot withdraw: it holds no shares, and shares are the only claim on capital.
        assertEq(pool.sharesOf(pricer), 0);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.CapitalLocked.selector, 1, 0));
        vm.prank(pricer);
        pool.withdrawCapital(1);

        assertEq(pool.capital(), capitalBefore, "pool capital moved");
        assertEq(asset.balanceOf(address(pool)), balanceBefore, "pool assets moved");
        assertEq(asset.balanceOf(pricer), 0, "pricer received assets");
    }

    /// @notice The pricing key cannot mint a policy, so it cannot create an obligation either.
    function test_PricerCannotMintAPolicy() public {
        _expectDenied(pricer, policy.VAULT_ROLE());
        vm.prank(pricer);
        policy.mintPolicy(
            pricer,
            address(asset),
            10_000e6,
            uint64(block.number) + 10_000,
            1e21,
            bytes32(0),
            bytes32(0)
        );
    }

    // --- the pricer cannot touch claim outcomes -------------------------------------------

    /// @notice The pricing key cannot alter whether, or how much, a claim pays.
    /// @dev The price is an input to what cover costs. It is not an input to whether a covered
    ///      event occurred, and this asserts the two cannot be confused: the pricer can neither
    ///      declare a claim, nor block one, nor change the payout of a policy already minted.
    function test_PricerCannotAlterClaimOutcome() public {
        uint256 id = _mint(10_000e6);
        vm.roll(policy.activeFromBlock(id));

        // Cannot declare a claim.
        _expectDenied(pricer, policy.CLAIM_ROLE());
        vm.prank(pricer);
        policy.markClaimable(id);

        // Cannot mark a policy paid to close it out.
        _expectDenied(pricer, policy.CLAIM_ROLE());
        vm.prank(pricer);
        policy.markPaid(id, 10_000e6);

        // Cannot cancel the policy out from under the holder before it can be claimed.
        _expectDenied(pricer, policy.VAULT_ROLE());
        vm.prank(pricer);
        policy.cancel(id);

        // A later pricing decision — even a refusal — does not touch the minted policy. The terms
        // were fixed at mint and the payout follows them, not the current price.
        _sign_and_record(true, 0, 7);
        assertEq(registry.declinedCount(), 1);

        ICoverPolicy.Policy memory p = policy.policies(id);
        assertEq(uint8(p.state), uint8(ICoverPolicy.PolicyState.Active), "policy state changed");
        assertEq(p.coverAmount, 10_000e6, "payout ceiling changed");
        assertEq(pool.coverOf(id), 10_000e6, "reservation changed");

        // The claim still settles in full, through the resolver, for the amount fixed at mint.
        vm.startPrank(resolver);
        policy.markClaimable(id);
        pool.payClaim(id, holder, 10_000e6);
        policy.markPaid(id, 10_000e6);
        vm.stopPrank();

        assertEq(asset.balanceOf(holder), 10_000e6, "payout was not the amount covered");
    }

    /// @notice The registry holds no capital and exposes no route to any.
    /// @dev The contract the pricing key does control is deliberately inert with respect to
    ///      money: it stores decisions and nothing else.
    function test_PricingRegistryHoldsNoValue() public view {
        assertEq(asset.balanceOf(address(registry)), 0);
        assertEq(address(registry).balance, 0);
    }

    // --- the admin cannot deny a valid claim ----------------------------------------------

    /// @notice Pausing halts new issuance and nothing else. A valid claim still settles.
    function test_AdminCannotDenyValidClaim() public {
        uint256 id = _mint(10_000e6);
        vm.roll(policy.activeFromBlock(id));

        vm.prank(admin);
        pool.pauseIssuance();
        assertTrue(pool.paused());

        // The admin has no function that denies a claim; the only lever is the pause, and the
        // claim path does not consult it.
        vm.startPrank(resolver);
        policy.markClaimable(id);
        pool.payClaim(id, holder, 10_000e6);
        policy.markPaid(id, 10_000e6);
        vm.stopPrank();

        assertEq(asset.balanceOf(holder), 10_000e6, "a paused admin blocked a valid claim");
        assertEq(uint8(policy.policies(id).state), uint8(ICoverPolicy.PolicyState.Paid));
    }

    /// @notice The admin cannot settle a claim either — not even in the holder's favour.
    /// @dev Discretion in either direction is discretion. Claims are the resolver's alone.
    function test_AdminCannotSettleAClaim() public {
        uint256 id = _mint(10_000e6);
        vm.roll(policy.activeFromBlock(id));

        _expectDenied(admin, policy.CLAIM_ROLE());
        vm.prank(admin);
        policy.markClaimable(id);

        _expectDenied(admin, pool.CLAIM_ROLE());
        vm.prank(admin);
        pool.payClaim(id, admin, 10_000e6);
    }

    /// @notice Pausing blocks issuance, never withdrawals.
    /// @dev A capital provider's ability to exit does not depend on anyone's cooperation.
    function test_PauseBlocksIssuanceButNeverWithdrawals() public {
        vm.prank(admin);
        pool.pauseIssuance();

        // Issuance is blocked.
        vm.expectRevert();
        vm.prank(vault);
        policy.mintPolicy(
            holder,
            address(asset),
            10_000e6,
            uint64(block.number) + 10_000,
            1e21,
            bytes32(0),
            bytes32(0)
        );

        // Withdrawal is not.
        uint256 shares = pool.sharesOf(provider);
        vm.prank(provider);
        uint256 assets = pool.withdrawCapital(shares);

        assertEq(assets, 1_000_000e6);
        assertEq(asset.balanceOf(provider), 1_000_000e6, "a pause stranded a provider's capital");
    }

    // --- reflexivity ----------------------------------------------------------------------

    /// @notice Pool capital is never supplied to the reserve the pool covers.
    /// @dev If it were, the collateral would lose value at exactly the moment claims trigger —
    ///      the reflexivity failure that broke first-generation cover protocols. `CoverPool` has
    ///      no `approve` call anywhere in it, so it can grant no allowance to the Aave Pool or to
    ///      anything else, and its assets can only leave via `withdrawCapital` or `payClaim`.
    function test_PoolCapitalIsNeverSuppliedToACoveredReserve() public view {
        assertEq(
            asset.allowance(address(pool), XLayerAddresses.POOL),
            0,
            "pool granted an allowance to the Aave Pool"
        );
        assertEq(asset.allowance(address(pool), address(policy)), 0);
        assertEq(asset.allowance(address(pool), admin), 0);

        // Belt and braces: the deployed bytecode contains no ERC20 approve selector, so no
        // allowance can be granted by any future call path either.
        bytes memory code = address(pool).code;
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        assertFalse(_containsSelector(code, approveSelector), "CoverPool can call approve");
        // The scan itself must work: a selector CoverPool certainly has is found.
        assertTrue(
            _containsSelector(code, bytes4(keccak256("capital()"))),
            "bytecode scan is broken, so the approve assertion above proves nothing"
        );
    }

    function _containsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1]
                    && code[i + 2] == selector[2] && code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    // --- helpers --------------------------------------------------------------------------

    function _sign_and_record(bool declined, uint256 rate, uint256 nonce)
        internal
        returns (bytes32)
    {
        PricingRegistry.Decision memory d = PricingRegistry.Decision({
            reserve: address(asset),
            coverAmount: 10_000e6,
            premiumRateRay: rate,
            validUntilBlock: uint64(block.number) + 50,
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
}
