// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./Deploy.s.sol";
import {AaveV3Venue} from "../src/venues/AaveV3Venue.sol";
import {IYieldVenue} from "../src/interfaces/IYieldVenue.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IAaveOracle} from "../src/interfaces/IAaveOracle.sol";
import {XLayerAddresses} from "../src/XLayerAddresses.sol";

/// @title DeployMainnet
/// @notice Deploys the full xCover set to X Layer mainnet, chain 196, against live Aave V3.
///
/// @dev **This is the production system.** Same xCover contracts as testnet, bound to the real USDT
///      reserve and the real Aave V3 Pool at the addresses verified in `docs/chain-verification.md`.
///      `AaveV3Venue` has no `induceDeficit` and no way to write any value the resolver reads —
///      there is a fork test asserting the selector is absent from its bytecode, mutation-checked.
///
///      **Do not run this before the testnet deployment exists and is recorded.** The order is an
///      eligibility gate, not a preference, and `deployments/xlayer-testnet.json` is the evidence.
///      The check below refuses to proceed without it.
///
/// Usage:
///   forge script script/DeployMainnet.s.sol --rpc-url $XLAYER_MAINNET_RPC --broadcast
contract DeployMainnet is DeployBase {
    function _aToken() internal pure override returns (address) {
        return XLayerAddresses.USDT_A_TOKEN;
    }

    function _grantVenueRole(IYieldVenue venue, address vault) internal override {
        AaveV3Venue(address(venue)).grantRole(AaveV3Venue(address(venue)).VAULT_ROLE(), vault);
    }

    function run() external {
        require(block.chainid == 196, "not X Layer mainnet (196)");

        // The testnet deployment must already exist. Reading its record rather than trusting a
        // checklist is the difference between a provable sequence and a claimed one.
        require(
            vm.exists("../../deployments/xlayer-testnet.json"),
            "deploy to testnet first: deployments/xlayer-testnet.json is missing"
        );

        // Aave must actually be here. If this is ever empty, the address book is wrong and a
        // deployment would bind the vault to nothing.
        require(XLayerAddresses.POOL.code.length > 0, "no Aave Pool at the recorded address");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address pricer = vm.addr(vm.envUint("PRICER_PRIVATE_KEY"));
        require(pricer != deployer, "pricer key must not be the deployer key");

        Params memory p = Params({
            // 24 hours at one second per block. Adverse selection is a real cost on mainnet, where
            // the capital at risk is real, so this is the full period rather than a demo-sized one.
            waitingPeriodBlocks: 86_400,
            // Launch capital is small by design; the cap bounds a single day's exposure well inside
            // it. The solvency check in CoverPool binds regardless — this only limits how fast new
            // cover can be written.
            dailyCoverCap: 100_000e6,
            // 30 minutes of blocks, sampled at least 30 times — roughly once a minute, comfortably
            // inside the 100 rps per-IP RPC limit that caps keeper frequency.
            windowBlocks: 1800,
            minSamples: 30,
            // $0.97, same reasoning and same evidence as testnet: the live oracle read $0.99896524
            // under normal conditions, about 10 bp off peg.
            depegLowerBound: 97_000_000,
            liquidityFloorBps: 10_000
        });

        vm.startBroadcast(pk);

        AaveV3Venue venue = new AaveV3Venue(
            IERC20(XLayerAddresses.USDT),
            IAaveV3Pool(XLayerAddresses.POOL),
            IERC20(XLayerAddresses.USDT_A_TOKEN),
            IAaveOracle(XLayerAddresses.USDT_ORACLE),
            deployer
        );

        Deployment memory d = _deploySystem(
            IERC20(XLayerAddresses.USDT), IYieldVenue(address(venue)), deployer, pricer, p
        );

        vm.stopBroadcast();

        _writeRecord("xlayer-mainnet", d, IYieldVenue(address(venue)));
    }
}
