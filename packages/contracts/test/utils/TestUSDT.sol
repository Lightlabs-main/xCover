// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A real ERC20 with USDT's 6 decimals, for unit and invariant tests only.
/// @dev SPEC §1.2.1 forbids mocks standing in for real dependencies anywhere outside a unit test.
///      This is not a mock of anything: it is a plain ERC20 used as the asset under test, so that
///      the pool's accounting is checked against genuine token transfers rather than an
///      approximation of them. Nothing outside `test/` may import it, and no deployment script
///      references it — the deployed asset is the verified USDT at
///      `XLayerAddresses.USDT` (0x779Ded0c9e1022225f8E0630b35a9b54bE713736).
contract TestUSDT is ERC20 {
    constructor() ERC20("Test USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
