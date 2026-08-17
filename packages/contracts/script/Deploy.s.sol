// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPolicy} from "../src/CoverPolicy.sol";
import {xCoverVault} from "../src/xCoverVault.sol";
import {ClaimResolver} from "../src/ClaimResolver.sol";
import {PricingRegistry} from "../src/PricingRegistry.sol";
import {ICoverPool} from "../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../src/interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "../src/interfaces/IYieldVenue.sol";

/// @title DeployBase
/// @notice The wiring both networks share, so neither can be wired differently by accident.
///
/// @dev **Why one base and two thin entry points.** The role table below is the whole system: get
///      one grant wrong and either nothing works or something works that must not. Writing it twice
///      — once for testnet, once for mainnet — would mean the mainnet deployment is wired by code
///      that has never been exercised, while the testnet run that *was* exercised proves nothing
///      about it. Here the only thing that differs between networks is the venue, the asset, and
///      the parameter set; the wiring is executed identically by both.
///
///      **Parameters are provisional and marked as such.** `bench/threshold-derivation.md` does not
///      exist yet, so the numbers in `Params` are reasoned defaults, not derived ones. The one that
///      is grounded in evidence is `depegLowerBound`: X Layer's USDT oracle read $0.99896524 on
///      2026-08-17, about 10 bp below peg under entirely normal conditions, so a threshold anywhere
///      near peg would fire on noise. Everything else is documented at its call site and must be
///      revisited before mainnet.
abstract contract DeployBase is Script {
    /// @notice Everything a deployment produces, in the order it is created.
    struct Deployment {
        address asset;
        address venue;
        address pool;
        address policy;
        address registry;
        address resolver;
        address vault;
        bytes32 termsHash;
    }

    /// @notice The knobs that legitimately differ between testnet and mainnet.
    struct Params {
        uint64 waitingPeriodBlocks;
        uint256 dailyCoverCap;
        uint64 windowBlocks;
        uint64 minSamples;
        uint256 depegLowerBound;
        uint256 liquidityFloorBps;
        uint256 deficitFloorBps;
    }

    /// @notice Both networks produce a block per second, measured over 500 blocks on 2026-08-17.
    /// @dev Recorded here because every window and waiting period below is denominated in blocks
    ///      and is meaningless without it.
    uint256 internal constant SECONDS_PER_BLOCK = 1;

    /// @dev The asset and venue are network-specific, so each entry point supplies its own.
    function _deploySystem(
        IERC20 asset,
        IYieldVenue venue,
        address admin,
        address pricer,
        Params memory p
    ) internal returns (Deployment memory d) {
        d.asset = address(asset);
        d.venue = address(venue);

        // --- contracts, in dependency order ------------------------------------------------
        CoverPool pool = new CoverPool(asset, admin);
        CoverPolicy policy =
            new CoverPolicy(ICoverPool(address(pool)), p.waitingPeriodBlocks, p.dailyCoverCap, admin);
        PricingRegistry registry = new PricingRegistry(admin);
        ClaimResolver resolver =
            new ClaimResolver(ICoverPool(address(pool)), ICoverPolicy(address(policy)), venue, admin);
        xCoverVault vault = new xCoverVault(
            asset, venue, ICoverPool(address(pool)), ICoverPolicy(address(policy)), registry, admin
        );

        d.pool = address(pool);
        d.policy = address(policy);
        d.registry = address(registry);
        d.resolver = address(resolver);
        d.vault = address(vault);

        // --- roles ------------------------------------------------------------------------
        // This is the table in HANDOFF.md §4. Every grant here is the minimum that makes one
        // specific call path work, and nothing holds a role it does not need.
        pool.grantRole(pool.VAULT_ROLE(), address(policy)); // reserve/release cover
        pool.grantRole(pool.CLAIM_ROLE(), address(resolver)); // pay a settled claim

        policy.grantRole(policy.VAULT_ROLE(), address(vault)); // mint and cancel positions
        policy.grantRole(policy.CLAIM_ROLE(), address(resolver)); // mark claimable, mark paid

        registry.grantRole(registry.PRICER_ROLE(), pricer); // sign quotes and refusals
        registry.grantRole(registry.VAULT_ROLE(), address(vault)); // consume a quote at mint

        // The venue is created by the caller, which therefore holds its admin role.
        _grantVenueRole(venue, address(vault));

        // --- terms ------------------------------------------------------------------------
        // The vault must know the terms before the first deposit, and the hash it fixes into each
        // policy must be the hash the resolver is later handed. Deriving both from one struct here
        // is what makes that true by construction rather than by careful copying.
        ClaimResolver.Terms memory terms = ClaimResolver.Terms({
            reserve: address(asset),
            aToken: _aToken(),
            windowBlocks: p.windowBlocks,
            minSamples: p.minSamples,
            depegLowerBound: p.depegLowerBound,
            liquidityFloorBps: p.liquidityFloorBps,
            deficitFloorBps: p.deficitFloorBps
        });
        d.termsHash = keccak256(abi.encode(terms));
        vault.setTermsHash(d.termsHash);

        _logDeployment(d, venue, terms);
    }

    /// @dev Overridden per network: the aToken the resolver reads redeemable liquidity from. There
    ///      is no aToken on testnet, where the venue holds the underlying itself.
    function _aToken() internal view virtual returns (address);

    /// @dev Both venues declare `VAULT_ROLE`, but they are different types, so the grant is done by
    ///      the concrete script that knows which one it built.
    function _grantVenueRole(IYieldVenue venue, address vault) internal virtual;

    function _logDeployment(
        Deployment memory d,
        IYieldVenue venue,
        ClaimResolver.Terms memory terms
    ) internal view {
        console2.log("--- xCover deployment -------------------------------");
        console2.log("chain id        ", block.chainid);
        console2.log("venue name      ", venue.venueName());
        console2.log("has yield source", venue.hasYieldSource());
        console2.log("asset           ", d.asset);
        console2.log("venue           ", d.venue);
        console2.log("CoverPool       ", d.pool);
        console2.log("CoverPolicy     ", d.policy);
        console2.log("PricingRegistry ", d.registry);
        console2.log("ClaimResolver   ", d.resolver);
        console2.log("xCoverVault     ", d.vault);
        console2.log("--- terms -------------------------------------------");
        console2.log("reserve         ", terms.reserve);
        console2.log("aToken          ", terms.aToken);
        console2.log("windowBlocks    ", terms.windowBlocks);
        console2.log("minSamples      ", terms.minSamples);
        console2.log("depegLowerBound ", terms.depegLowerBound);
        console2.log("liquidityFloorBps", terms.liquidityFloorBps);
        console2.log("deficitFloorBps ", terms.deficitFloorBps);
        console2.log("termsHash       ", vm.toString(d.termsHash));
    }

    /// @dev Written to `deployments/<network>.json` and committed, so the testnet-before-mainnet
    ///      order is visible without anyone taking our word for it.
    ///
    ///      **Only a real broadcast writes it.** A simulation produces addresses that look exactly
    ///      like deployed ones and are not, so a dry run that wrote this file would manufacture
    ///      evidence of a deployment that never happened — and would satisfy the ordering gate in
    ///      `DeployMainnet` on the strength of it. The record is a claim about the chain, so only an
    ///      action against the chain may make it.
    function _writeRecord(string memory network, Deployment memory d, IYieldVenue venue) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("simulation only: deployments/%s.json not written", network);
            return;
        }

        string memory path = string.concat("../../deployments/", network, ".json");
        string memory key = "deployment";

        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeUint(key, "timestamp", block.timestamp);
        vm.serializeString(key, "venueName", venue.venueName());
        vm.serializeBool(key, "hasYieldSource", venue.hasYieldSource());
        vm.serializeAddress(key, "asset", d.asset);
        vm.serializeAddress(key, "venue", d.venue);
        vm.serializeAddress(key, "coverPool", d.pool);
        vm.serializeAddress(key, "coverPolicy", d.policy);
        vm.serializeAddress(key, "pricingRegistry", d.registry);
        vm.serializeAddress(key, "claimResolver", d.resolver);
        vm.serializeAddress(key, "xCoverVault", d.vault);
        string memory json = vm.serializeBytes32(key, "termsHash", d.termsHash);

        vm.writeJson(json, path);
        console2.log("record written to", path);
    }
}
