// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPolicy} from "../src/CoverPolicy.sol";
import {xCoverVault} from "../src/xCoverVault.sol";
import {ClaimResolver} from "../src/ClaimResolver.sol";
import {PricingRegistry} from "../src/PricingRegistry.sol";
import {TestnetVenue} from "../src/venues/TestnetVenue.sol";
import {TestnetUSDT} from "../src/testnet/TestnetUSDT.sol";
import {ICoverPolicy} from "../src/interfaces/ICoverPolicy.sol";

/// @title LifecycleTestnet
/// @notice Drives the deployed testnet system through the real path, on chain, in stages.
///
/// @dev **Why this exists as a script and not a test.** The fork tests prove the logic against live
///      Aave inside an EVM this repository controls. Nothing in that proves the *deployed* system is
///      wired correctly — a missing role grant or an unset terms hash passes every test and breaks
///      every deposit. SPEC §1.3 says nothing is done until it has run end to end against a real
///      dependency on a real chain, and for the deployment itself, this is that run.
///
///      **It is staged because the chain is.** A 300-block waiting period and a 120-block sampling
///      window are real elapsed time; no script can skip them. So each stage is a separate
///      invocation and reads the state the previous one left behind, which is also what a keeper and
///      a user actually do.
///
/// Usage, in order:
///   forge script script/LifecycleTestnet.s.sol --sig "open()"    --rpc-url $XLAYER_TESTNET_RPC --broadcast
///   forge script script/LifecycleTestnet.s.sol --sig "refuse()"  --rpc-url $XLAYER_TESTNET_RPC --broadcast
///   forge script script/LifecycleTestnet.s.sol --sig "observe()" --rpc-url $XLAYER_TESTNET_RPC --broadcast
///   forge script script/LifecycleTestnet.s.sol --sig "trigger()" --rpc-url $XLAYER_TESTNET_RPC --broadcast
///   forge script script/LifecycleTestnet.s.sol --sig "settle()"  --rpc-url $XLAYER_TESTNET_RPC --broadcast
contract LifecycleTestnet is Script {
    // Read from the committed deployment record rather than pasted in, so this script cannot
    // silently drift onto a stale deployment.
    struct Addrs {
        TestnetUSDT asset;
        TestnetVenue venue;
        CoverPool pool;
        CoverPolicy policy;
        PricingRegistry registry;
        ClaimResolver resolver;
        xCoverVault vault;
        bytes32 termsHash;
    }

    uint256 internal constant CAPITAL = 100_000e6;
    uint256 internal constant DEPOSIT = 10_000e6;
    uint64 internal constant TERM_BLOCKS = 100_000;

    // Must match DeployTestnet's Params exactly, or the resolver rejects the terms hash. That it
    // *would* reject them is the point of the hash; this is the honest way to satisfy it.
    uint64 internal constant WINDOW_BLOCKS = 120;
    uint64 internal constant MIN_SAMPLES = 5;
    uint256 internal constant DEPEG_LOWER_BOUND = 97_000_000;
    uint256 internal constant LIQUIDITY_FLOOR_BPS = 10_000;

    function _load() internal view returns (Addrs memory a) {
        string memory json = vm.readFile("../../deployments/xlayer-testnet.json");
        a.asset = TestnetUSDT(vm.parseJsonAddress(json, ".asset"));
        a.venue = TestnetVenue(vm.parseJsonAddress(json, ".venue"));
        a.pool = CoverPool(vm.parseJsonAddress(json, ".coverPool"));
        a.policy = CoverPolicy(vm.parseJsonAddress(json, ".coverPolicy"));
        a.registry = PricingRegistry(vm.parseJsonAddress(json, ".pricingRegistry"));
        a.resolver = ClaimResolver(vm.parseJsonAddress(json, ".claimResolver"));
        a.vault = xCoverVault(vm.parseJsonAddress(json, ".xCoverVault"));
        a.termsHash = vm.parseJsonBytes32(json, ".termsHash");
        require(block.chainid == 1952, "not X Layer testnet (1952)");
    }

    function _terms(Addrs memory a) internal pure returns (ClaimResolver.Terms memory) {
        return ClaimResolver.Terms({
            reserve: address(a.asset),
            aToken: address(0),
            windowBlocks: WINDOW_BLOCKS,
            minSamples: MIN_SAMPLES,
            depegLowerBound: DEPEG_LOWER_BOUND,
            liquidityFloorBps: LIQUIDITY_FLOOR_BPS
        });
    }

    /// @dev Signs a decision with the pricer key and records it. This is what the pricing agent will
    ///      do once it exists; the signature is checked by the registry either way, so a hand-signed
    ///      decision is not a shortcut around the trust model — it is the same door.
    function _signAndRecord(
        Addrs memory a,
        uint256 pricerPk,
        uint256 coverAmount,
        uint256 premiumRateRay,
        bool declined,
        uint256 nonce
    ) internal returns (bytes32 quoteHash) {
        PricingRegistry.Decision memory d = PricingRegistry.Decision({
            reserve: address(a.asset),
            coverAmount: coverAmount,
            premiumRateRay: premiumRateRay,
            validUntilBlock: uint64(block.number) + 300,
            declined: declined,
            decisionHash: keccak256(abi.encodePacked("manual-decision", nonce)),
            engineVersion: "manual-0.0.0/xlayer-testnet-lifecycle",
            nonce: nonce
        });

        bytes32 digest = a.registry.hashDecision(d);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pricerPk, digest);
        quoteHash = a.registry.recordDecision(d, abi.encodePacked(r, s, v));
    }

    // --- stage 1: capital, a quote, and a covered deposit ---------------------------------

    function open() external {
        Addrs memory a = _load();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 pricerPk = vm.envUint("PRICER_PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        // Underwriting capital. Without it the mint fails the solvency check, which is correct.
        a.asset.mint(me, CAPITAL + DEPOSIT);
        a.asset.approve(address(a.pool), CAPITAL);
        a.pool.depositCapital(CAPITAL);

        // A real signed quote: 1e18 ray per block is a token rate for the rehearsal, not a priced
        // one. Pricing is the agent's job and the agent does not exist yet.
        bytes32 quoteHash = _signAndRecord(a, pricerPk, DEPOSIT, 1e18, false, block.number);

        a.asset.approve(address(a.vault), DEPOSIT);
        (uint256 shares, uint256 policyId) =
            a.vault.depositCovered(DEPOSIT, me, quoteHash, TERM_BLOCKS);

        vm.stopBroadcast();

        console2.log("policy id       ", policyId);
        console2.log("shares          ", shares);
        console2.log("pool capital    ", a.pool.capital());
        console2.log("outstandingCover", a.pool.outstandingCover());
        console2.log("cover active at ", a.policy.activeFromBlock(policyId));
        console2.log("current block   ", block.number);
    }

    // --- stage 2: the refusal path, recorded on chain -------------------------------------

    /// @dev A refusal is a first-class outcome and the registry records it on the same path as a
    ///      quote. Proving that live matters as much as proving a payout: a system that can only be
    ///      shown succeeding has not been shown to be honest.
    function refuse() external {
        Addrs memory a = _load();
        uint256 pricerPk = vm.envUint("PRICER_PRIVATE_KEY");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        bytes32 quoteHash = _signAndRecord(a, pricerPk, DEPOSIT, 0, true, block.number + 1);
        vm.stopBroadcast();

        console2.log("refusal recorded", vm.toString(quoteHash));
        console2.log("declinedCount   ", a.registry.declinedCount());
        console2.log("quotedCount     ", a.registry.quotedCount());
    }

    // --- stage 3: induce a real loss, then witness it across the window --------------------

    /// @dev Writes off real assets and records one observation. Call repeatedly, in separate blocks,
    ///      until `minSamples` observations sit inside the window. The deficit is induced once; the
    ///      subsequent calls only observe.
    function observe() external {
        Addrs memory a = _load();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        if (a.venue.deficit() == 0) {
            a.venue.induceDeficit(address(a.asset), DEPOSIT);
        }
        a.resolver.recordObservation(address(a.asset), address(0));
        vm.stopBroadcast();

        console2.log("venue deficit   ", a.venue.deficit());
        console2.log("observations    ", a.resolver.observationCount(address(a.asset)));
        console2.log("block           ", block.number);
    }

    // --- stage 4: evaluate, and --- stage 5: settle ---------------------------------------

    function trigger() external {
        Addrs memory a = _load();
        uint256 policyId = vm.envUint("POLICY_ID");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        ClaimResolver.Trigger t = a.resolver.evaluate(policyId, _terms(a));
        vm.stopBroadcast();

        console2.log("trigger         ", uint256(t));
        console2.log("claim amount    ", a.resolver.claimAmount(policyId));
    }

    function settle() external {
        Addrs memory a = _load();
        uint256 policyId = vm.envUint("POLICY_ID");
        address holder = a.policy.ownerOf(policyId);
        uint256 before = a.asset.balanceOf(holder);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 paid = a.resolver.claim(policyId);
        vm.stopBroadcast();

        console2.log("paid            ", paid);
        console2.log("holder delta    ", a.asset.balanceOf(holder) - before);
        console2.log("pool capital    ", a.pool.capital());
        console2.log("outstandingCover", a.pool.outstandingCover());
    }
}
