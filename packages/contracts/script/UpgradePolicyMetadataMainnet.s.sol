// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPolicy} from "../src/CoverPolicy.sol";
import {PricingRegistry} from "../src/PricingRegistry.sol";
import {ClaimResolver} from "../src/ClaimResolver.sol";
import {xCoverVault} from "../src/xCoverVault.sol";
import {AaveV3Venue} from "../src/venues/AaveV3Venue.sol";
import {ICoverPool} from "../src/interfaces/ICoverPool.sol";
import {ICoverPolicy} from "../src/interfaces/ICoverPolicy.sol";
import {IYieldVenue} from "../src/interfaces/IYieldVenue.sol";
import {XLayerAddresses} from "../src/XLayerAddresses.sol";

/// @notice Replaces only policy-linked components while preserving the funded pool, pricing
/// registry and Aave venue. The old issuance path is revoked in the same broadcast.
contract UpgradePolicyMetadataMainnet is Script {
    CoverPool internal constant POOL = CoverPool(0xe47298EA2ce467555044Dd707A646F9dF863bb87);
    PricingRegistry internal constant REGISTRY =
        PricingRegistry(0x35072d8AB440B3b52942A04B5a67179e46eF6692);
    AaveV3Venue internal constant VENUE =
        AaveV3Venue(0x23a2Ae137030034e604fEE085169bfaFad6Fc1a9);

    CoverPolicy internal constant OLD_POLICY =
        CoverPolicy(0xD4A4Dd34e76e42ec206f65D0fC9F7eCb09A895fa);
    ClaimResolver internal constant OLD_RESOLVER =
        ClaimResolver(0xa18Ae50fc36194833155084bE21962EC3695aF3D);
    xCoverVault internal constant OLD_VAULT =
        xCoverVault(0x51025304e7aaaB594F55e8d92DF334257A65E2Be);

    function run() external {
        require(block.chainid == 196, "not X Layer mainnet");
        require(POOL.outstandingCover() == 0, "old policies still reserve capital");
        require(VENUE.totalAssets() == 0, "old covered deposits still in venue");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(POOL.hasRole(POOL.DEFAULT_ADMIN_ROLE(), deployer), "deployer not pool admin");
        require(REGISTRY.hasRole(REGISTRY.DEFAULT_ADMIN_ROLE(), deployer), "deployer not registry admin");
        require(VENUE.hasRole(VENUE.DEFAULT_ADMIN_ROLE(), deployer), "deployer not venue admin");

        ClaimResolver.Terms memory terms = ClaimResolver.Terms({
            reserve: XLayerAddresses.USDT,
            aToken: XLayerAddresses.USDT_A_TOKEN,
            windowBlocks: 1800,
            minSamples: 30,
            maxObservationGapBlocks: 60,
            depegLowerBound: 97_000_000,
            liquidityFloorBps: 10_000,
            deficitFloorBps: 50
        });
        bytes32 termsHash = keccak256(abi.encode(terms));

        vm.startBroadcast(pk);

        CoverPolicy policy = new CoverPolicy(ICoverPool(address(POOL)), 86_400, 100_000e6, deployer);
        ClaimResolver resolver = new ClaimResolver(
            ICoverPool(address(POOL)), ICoverPolicy(address(policy)), IYieldVenue(address(VENUE)), deployer
        );
        xCoverVault vault = new xCoverVault(
            IERC20(XLayerAddresses.USDT),
            IYieldVenue(address(VENUE)),
            ICoverPool(address(POOL)),
            ICoverPolicy(address(policy)),
            REGISTRY,
            deployer
        );

        POOL.grantRole(POOL.VAULT_ROLE(), address(policy));
        POOL.grantRole(POOL.CLAIM_ROLE(), address(resolver));
        policy.grantRole(policy.VAULT_ROLE(), address(vault));
        policy.grantRole(policy.CLAIM_ROLE(), address(resolver));
        REGISTRY.grantRole(REGISTRY.VAULT_ROLE(), address(vault));
        VENUE.grantRole(VENUE.VAULT_ROLE(), address(vault));
        vault.setTermsHash(termsHash);

        // Disable the superseded path after the replacement is completely wired.
        POOL.revokeRole(POOL.VAULT_ROLE(), address(OLD_POLICY));
        POOL.revokeRole(POOL.CLAIM_ROLE(), address(OLD_RESOLVER));
        OLD_POLICY.revokeRole(OLD_POLICY.VAULT_ROLE(), address(OLD_VAULT));
        OLD_POLICY.revokeRole(OLD_POLICY.CLAIM_ROLE(), address(OLD_RESOLVER));
        REGISTRY.revokeRole(REGISTRY.VAULT_ROLE(), address(OLD_VAULT));
        VENUE.revokeRole(VENUE.VAULT_ROLE(), address(OLD_VAULT));

        vm.stopBroadcast();

        console2.log("CoverPool       ", address(POOL));
        console2.log("CoverPolicy     ", address(policy));
        console2.log("PricingRegistry ", address(REGISTRY));
        console2.log("ClaimResolver   ", address(resolver));
        console2.log("xCoverVault     ", address(vault));
        console2.logBytes32(termsHash);
    }
}
