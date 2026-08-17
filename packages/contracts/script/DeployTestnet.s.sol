// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./Deploy.s.sol";
import {TestnetVenue} from "../src/venues/TestnetVenue.sol";
import {TestnetUSDT} from "../src/testnet/TestnetUSDT.sol";
import {IYieldVenue} from "../src/interfaces/IYieldVenue.sol";
import {XLayerAddresses} from "../src/XLayerAddresses.sol";

/// @title DeployTestnet
/// @notice Deploys the full xCover set to X Layer testnet, chain 1952.
///
/// @dev **What is different here, stated plainly.** Aave V3 is not deployed on X Layer testnet —
///      verified on 2026-08-17, empty code at both `POOL` and `POOL_ADDRESSES_PROVIDER`. So this
///      deployment runs `TestnetVenue`, a real custody-only venue that pays no yield and says so,
///      against `TestnetUSDT`, a real ERC-20 standing in for a USDT that does not exist on 1952.
///      Every xCover contract is byte-for-byte the one mainnet runs. What testnet proves is the
///      lifecycle; what it does not prove is the Aave integration, which is proven instead by the
///      fork tests and by the mainnet deployment.
///
///      **The parameters are deliberately faster than mainnet's**, and this is the one place the two
///      networks genuinely diverge in behaviour rather than in dependencies. A 24-hour waiting
///      period and a 30-minute sampling window would make the judge-triggerable claim in SPEC §3.5
///      impossible to actually watch. Testnet therefore uses a 5-minute waiting period and a
///      2-minute window. The deployment record carries both parameter sets so the difference is
///      never something a reader has to discover.
///
/// Usage:
///   forge script script/DeployTestnet.s.sol --rpc-url $XLAYER_TESTNET_RPC --broadcast
contract DeployTestnet is DeployBase {
    /// @dev No aToken exists here: `TestnetVenue` holds the underlying itself and ignores this
    ///      argument when reporting redeemable liquidity.
    function _aToken() internal pure override returns (address) {
        return address(0);
    }

    function _grantVenueRole(IYieldVenue venue, address vault) internal override {
        TestnetVenue(address(venue)).grantRole(TestnetVenue(address(venue)).VAULT_ROLE(), vault);
    }

    function run() external {
        require(block.chainid == 1952, "not X Layer testnet (1952)");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address pricer = vm.addr(vm.envUint("PRICER_PRIVATE_KEY"));

        // The pricing key must not be the deployer key. The deployer holds ADMIN_ROLE; the pricer
        // signs quotes. Collapsing them would mean a compromised pricing key also carries admin
        // rights, which is the separation in SPEC §4.7 undone at deployment time.
        require(pricer != deployer, "pricer key must not be the deployer key");

        Params memory p = Params({
            // 5 minutes. Still a real adverse-selection control — a buyer cannot see trouble and
            // insure against it in the same breath — but short enough to demonstrate live.
            waitingPeriodBlocks: 300,
            dailyCoverCap: 1_000_000e6,
            // 2 minutes of blocks, sampled at least 5 times. Enough that one manipulated block
            // cannot trigger a payout, which is the property the window exists for.
            windowBlocks: 120,
            minSamples: 5,
            // $0.97. Normal conditions on X Layer already sit ~10 bp off peg, so this clears the
            // observed noise floor by roughly 30x rather than firing on it.
            depegLowerBound: 97_000_000,
            // Redeemable liquidity below 1x the cover written is a redemption failure.
            liquidityFloorBps: 10_000
        });

        vm.startBroadcast(pk);

        TestnetUSDT asset = new TestnetUSDT();
        TestnetVenue venue = new TestnetVenue(IERC20(address(asset)), deployer);

        Deployment memory d =
            _deploySystem(IERC20(address(asset)), IYieldVenue(address(venue)), deployer, pricer, p);

        vm.stopBroadcast();

        _writeRecord("xlayer-testnet", d, IYieldVenue(address(venue)));
    }
}
