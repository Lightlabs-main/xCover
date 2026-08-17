// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestnetUSDT
/// @notice The covered asset for the X Layer **testnet** deployment only.
///
/// @dev **Why this exists.** Launch covers USDT, and the USDT in `XLayerAddresses` is a mainnet
///      address with no counterpart on X Layer testnet. Without a covered asset that exists on
///      1952, the testnet deployment could not accept a deposit, which would cost the lifecycle
///      rehearsal and the judge-triggerable claim that SPEC §3.5 says testnet is for.
///
///      **This is not a mock, on the same reasoning that covers `TestnetVenue`.** A mock returns
///      fabricated data so a demo looks complete. This is a real ERC-20 with real balances and real
///      transfers, deployed to a real chain, standing in for a production dependency that is absent
///      from that chain. It mirrors mainnet USDT where it matters — 6 decimals — so amounts, the
///      oracle's 8-decimal peg comparison, and the pricing terms are the same numbers on both
///      networks rather than quietly rescaled on one.
///
///      **`mint` is open on purpose.** A judge needs tokens to run a deposit without asking anyone
///      for them, and there is nothing to protect: this token is worthless by construction and
///      exists on a test network. On mainnet this contract is not deployed at all — the deployment
///      script binds the mainnet vault to the real USDT — and the deployment record states which
///      asset each network covers.
contract TestnetUSDT is ERC20 {
    /// @notice Mirrors mainnet USDT. Verified on chain: 6 decimals.
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("xCover Test USDT", "tUSDT") {}

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mint `amount` to `to`. Deliberately unpermissioned — see the contract note.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
